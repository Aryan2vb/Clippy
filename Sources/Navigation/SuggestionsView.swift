import SwiftUI
import ClippyCore
import ClippyEngine

// MARK: - Suggestions State

@MainActor
class SuggestionsState: ObservableObject {
    @Published var isAvailable = false
    @Published var isChecking = true
    @Published var isAnalyzing = false
    @Published var suggestions: [LLMSuggestion] = []
    @Published var selectedSuggestions: Set<UUID> = []
    @Published var errorMessage: String?
    
    let engine = LLMEngine()
    
    func toggleSelection(for suggestion: LLMSuggestion) {
        if selectedSuggestions.contains(suggestion.id) {
            selectedSuggestions.remove(suggestion.id)
        } else {
            selectedSuggestions.insert(suggestion.id)
        }
    }
    
    func selectAll() {
        selectedSuggestions = Set(suggestions.map { $0.id })
    }
    
    func deselectAll() {
        selectedSuggestions.removeAll()
    }
    
    func checkOllama() {
        Task {
            let available = await engine.isAvailable()
            await MainActor.run {
                self.isAvailable = available
                self.isChecking = false
            }
        }
    }
    
    func analyze(rootURL: URL) {
        isAnalyzing = true
        errorMessage = nil
        suggestions = []
        
        Task.detached {
            // Build tree summary
            let fileManager = FileManager.default
            var totalFiles = 0
            var totalBytes: Int64 = 0
            var topItems: [FolderTreeItem] = []
            
            // Shallow scan for top-level items
            do {
                let contents = try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                
                for itemURL in contents {
                    let attrs = try? fileManager.attributesOfItem(atPath: itemURL.path)
                    let isDirectory = (attrs?[.type] as? FileAttributeType) == .typeDirectory
                    let modDate = (attrs?[.modificationDate] as? Date) ?? Date()
                    let daysAgo = Calendar.current.dateComponents([.day], from: modDate, to: Date()).day ?? 0
                    
                    var size: Int64 = 0
                    var fileCount = 0
                    
                    if isDirectory {
                        // Quick scan internal for size and filecount
                        if let enumerator = fileManager.enumerator(at: itemURL, includingPropertiesForKeys: [.fileSizeKey]) {
                            for case let fileURL as URL in enumerator {
                                fileCount += 1
                                if let res = try? fileURL.resourceValues(forKeys: [.fileSizeKey]), let fs = res.fileSize {
                                    size += Int64(fs)
                                }
                            }
                        }
                    } else {
                        size = (attrs?[.size] as? Int64) ?? 0
                        fileCount = 1
                    }
                    
                    totalFiles += fileCount
                    totalBytes += size
                    
                    // Limit to 200 top items to avoid token overflow
                    if topItems.count < 200 {
                        let item = FolderTreeItem(
                            name: itemURL.lastPathComponent,
                            fullPath: itemURL.path,
                            isDirectory: isDirectory,
                            sizeBytes: size,
                            fileCount: fileCount,
                            extension: isDirectory ? nil : itemURL.pathExtension,
                            modifiedDaysAgo: daysAgo
                        )
                        print("SuggestionsView: Adding item - name: \(item.name), fullPath: \(item.fullPath), isDirectory: \(item.isDirectory)")
                        topItems.append(item)
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to scan folder: \(error.localizedDescription)"
                    self.isAnalyzing = false
                }
                return
            }
            
            let summary = FolderTreeSummary(
                rootPath: rootURL.path,
                totalFiles: totalFiles,
                totalSizeBytes: totalBytes,
                topLevelItems: topItems
            )
            
            do {
                let sugs = try await self.engine.generateSuggestions(folderTree: summary)
                
                // Filter out excluded folders from suggestions
                let excluded = ["node_modules", ".git", ".venv", "Pods", "__pycache__"]
                let filteredSuggestions = sugs.map { suggestion in
                    let filteredPaths = suggestion.affectedPaths.filter { path in
                        !excluded.contains { excludedFolder in
                            path.contains("/\(excludedFolder)/") || path.hasSuffix("/\(excludedFolder)")
                        }
                    }
                    return LLMSuggestion(
                        id: suggestion.id,
                        type: suggestion.type,
                        description: suggestion.description,
                        affectedPaths: filteredPaths,
                        suggestedAction: suggestion.suggestedAction,
                        confidence: suggestion.confidence
                    )
                }
                
                await MainActor.run {
                    self.suggestions = filteredSuggestions
                    self.selectedSuggestions.removeAll()
                    self.isAnalyzing = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isAnalyzing = false
                }
            }
        }
    }
    
    func approve(suggestion: LLMSuggestion, appState: AppState) {
        convertSuggestionToActionPlan(suggestion: suggestion, appState: appState)
    }
    
    func approveAll(appState: AppState) {
        // Approve all suggestions one by one
        let suggestionsToApprove = self.suggestions
        for suggestion in suggestionsToApprove {
            self.convertSuggestionToActionPlan(suggestion: suggestion, appState: appState)
        }
        // Clear all suggestions after approving
        self.suggestions.removeAll()
        self.selectedSuggestions.removeAll()
    }
    
    func approveSelected(appState: AppState) {
        // Only approve selected suggestions
        let suggestionsToApprove = self.suggestions.filter { selectedSuggestions.contains($0.id) }
        for suggestion in suggestionsToApprove {
            self.convertSuggestionToActionPlan(suggestion: suggestion, appState: appState)
        }
        // Remove approved suggestions from list
        self.suggestions.removeAll { selectedSuggestions.contains($0.id) }
        self.selectedSuggestions.removeAll()
    }
    
    private func convertSuggestionToActionPlan(suggestion: LLMSuggestion, appState: AppState) {
         Task.detached {
            var newActions: [PlannedAction] = []
            
            guard let root = await appState.selectedFolderURL else {
                print("SuggestionsView: No selected folder, cannot create action plan")
                return
            }
            
            let destFolderName = determineDestinationFolder(suggestion: suggestion, rootURL: root)
            let destFolderURL = root.appendingPathComponent(destFolderName)
            
            // Build actions first - validate files
            print("SuggestionsView: Processing \(suggestion.affectedPaths.count) affectedPaths")
            for path in suggestion.affectedPaths {
                print("SuggestionsView: Checking path: \(path)")
                let url = URL(fileURLWithPath: path)
                
                // Check if file exists
                var isDirectory: ObjCBool = false
                let fileExists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                print("SuggestionsView: fileExists = \(fileExists), isDirectory = \(isDirectory.boolValue)")
                
                if !fileExists {
                    print("SuggestionsView: File does not exist at \(path)")
                    continue
                }
                
                if isDirectory.boolValue {
                    print("SuggestionsView: Skipping directory \(path)")
                    continue
                }
                
                print("SuggestionsView: Processing file at \(path)")
                
                // Construct a FileDescriptor
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                let fd = FileDescriptor(
                    fileURL: url,
                    fileName: url.lastPathComponent,
                    fileExtension: url.pathExtension,
                    fileSize: (attrs?[.size] as? Int64) ?? 0,
                    createdAt: (attrs?[.creationDate] as? Date) ?? Date(),
                    modifiedAt: (attrs?[.modificationDate] as? Date) ?? Date(),
                    isDirectory: false,
                    isSymlink: false,
                    permissionsReadable: true
                )
                
                let actionType: ActionType = .move(destination: destFolderURL.appendingPathComponent(url.lastPathComponent))
                
                let action = PlannedAction(
                    targetFile: fd,
                    actionType: actionType,
                    reason: "AI: \(suggestion.description)"
                )
                newActions.append(action)
            }
            
            // Only create folder if there are valid files to move
            guard !newActions.isEmpty else {
                await MainActor.run {
                    self.errorMessage = "No valid files found for '\(suggestion.description)'. Files may have been moved or deleted."
                    self.suggestions.removeAll { $0.id == suggestion.id }
                }
                return
            }
            
            // NOW create the folder
            do {
                try FileManager.default.createDirectory(at: destFolderURL, withIntermediateDirectories: true)
            } catch {
                print("SuggestionsView: Failed to create folder \(destFolderURL.path): \(error)")
                await MainActor.run {
                    self.errorMessage = "Could not create folder '\(destFolderName)': \(error.localizedDescription)"
                    self.isAnalyzing = false
                }
                return
            }
            
            let finalActions = newActions
            
            await MainActor.run {
                if let existingPlan = appState.actionPlan {
                    // Check for duplicate paths - only add actions that don't already exist in the plan
                    let existingPaths = Set(existingPlan.actions.map { $0.targetFile.fileURL.path })
                    let uniqueActions = finalActions.filter { !existingPaths.contains($0.targetFile.fileURL.path) }
                    
                    // Swift structs are immutable unless mapped
                    let updatedPlan = ActionPlan(actions: existingPlan.actions + uniqueActions)
                    appState.actionPlan = updatedPlan
                } else {
                    appState.actionPlan = ActionPlan(actions: finalActions)
                }
                
                // Remove from suggestions array
                self.suggestions.removeAll { $0.id == suggestion.id }
            }
        }
    }
    
    func dismiss(suggestion: LLMSuggestion) {
        suggestions.removeAll { $0.id == suggestion.id }
    }
}

// MARK: - Suggestions View

struct SuggestionsView: View {
    @ObservedObject var appState: AppState
    @StateObject private var state = SuggestionsState()
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            
            if state.isChecking {
                ProgressView("Connecting to Ollama...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !state.isAvailable {
                ollamaMissingView
            } else if appState.selectedFolderURL == nil {
                noFolderView
            } else if state.isAnalyzing {
                analyzingView
            } else if let err = state.errorMessage {
                errorView(msg: err)
            } else if state.suggestions.isEmpty {
                emptySuggestionsView
            } else {
                suggestionsList
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .onAppear {
            state.checkOllama()
        }
    }
    
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI Suggestions").font(.title2).fontWeight(.semibold)
                
                HStack(spacing: 6) {
                    Circle()
                        .fill(state.isAvailable ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(state.isAvailable ? "Ollama connected — \(state.engine.selectedModel)" : "Ollama not found — Install Ollama to enable")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            
            if state.isAvailable && appState.selectedFolderURL != nil && !state.isAnalyzing {
                Button {
                    if let url = appState.selectedFolderURL {
                        state.analyze(rootURL: url)
                    }
                } label: {
                    Label("Generate Suggestions", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private var ollamaMissingView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            Text("Ollama Not Running")
                .font(.title3).fontWeight(.medium)
            Text("This feature requires Ollama running locally on port 11434.")
                .font(.body).foregroundColor(.secondary)
            
            if let url = URL(string: "https://ollama.ai") {
                Link(destination: url) {
                    Text("Get Ollama")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .padding(.top, 8)
            }
            
            Button("Check Again") {
                state.isChecking = true
                state.checkOllama()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var noFolderView: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
            Text("No Folder Selected")
                .font(.title3).fontWeight(.medium)
            Text("Select a folder in the organize tab first.")
                .font(.body).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var analyzingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)
            Text("Analyzing your folder structure...")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var emptySuggestionsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundColor(.accentColor.opacity(0.5))
            Text("No Suggestions")
                .font(.title3).fontWeight(.medium)
            Text("Run an analysis to get AI-powered insights.")
                .font(.body).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func errorView(msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "xmark.octagon")
                .font(.system(size: 48))
                .foregroundColor(.red.opacity(0.8))
            Text("Analysis Failed")
                .font(.title3).fontWeight(.medium)
            Text(msg)
                .font(.caption).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var suggestionsList: some View {
        List {
            // Settings row
            Section {
                providerPicker
                modelSelector
            }
            
            Section(header: HStack {
                Text("Suggestions").font(.headline).foregroundColor(.secondary)
                Spacer()
                if !state.suggestions.isEmpty {
                    Menu {
                        Button("Select All") {
                            state.selectAll()
                        }
                        Button("Deselect All") {
                            state.deselectAll()
                        }
                        Divider()
                        Button("Approve Selected (\(state.selectedSuggestions.count))") {
                            state.approveSelected(appState: appState)
                        }
                        .disabled(state.selectedSuggestions.isEmpty)
                        Button("Approve All") {
                            state.approveAll(appState: appState)
                        }
                    } label: {
                        Label("Actions", systemImage: "ellipsis.circle")
                    }
                    .controlSize(.small)
                }
            }) {
                ForEach(state.suggestions) { suggestion in
                    SuggestionCard(
                        suggestion: suggestion,
                        isSelected: state.selectedSuggestions.contains(suggestion.id),
                        onToggleSelection: { state.toggleSelection(for: suggestion) },
                        onApprove: {
                            state.approve(suggestion: suggestion, appState: appState)
                        }, onDismiss: {
                            state.dismiss(suggestion: suggestion)
                        })
                }
            }
        }
        .listStyle(.inset)
    }
    
    // MARK: - Computed Properties
    
    private var providerPicker: some View {
        Picker("Provider", selection: Binding(
            get: { state.engine.selectedProvider },
            set: { newProvider in
                state.engine.selectedProvider = newProvider
                // Auto-switch to appropriate default model
                switch newProvider {
                case .ollama:
                    state.engine.selectedModel = "llama3.2:3b"
                case .groq:
                    state.engine.selectedModel = "openai/gpt-oss-120b"
                }
                state.checkOllama()
            }
        )) {
            ForEach(LLMProvider.allCases, id: \.self) { provider in
                Text(provider.displayName).tag(provider)
            }
        }
    }
    
    @ViewBuilder
    private var modelSelector: some View {
        if state.engine.selectedProvider == .ollama {
            HStack {
                Text("Model")
                Spacer()
                TextField("Model name", text: Binding(
                    get: { state.engine.selectedModel },
                    set: { state.engine.selectedModel = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
            }
        } else if state.engine.selectedProvider == .groq {
            HStack {
                Text("Model")
                Spacer()
                Picker("Model", selection: Binding(
                    get: { state.engine.selectedModel },
                    set: { state.engine.selectedModel = $0 }
                )) {
                    ForEach(state.engine.getGroqModels(), id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200)
            }
            
            HStack {
                Text("API Key")
                Spacer()
                SecureField("Groq API Key", text: Binding(
                    get: { state.engine.groqAPIKey },
                    set: { state.engine.groqAPIKey = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            }
            
            Button("Check Availability") {
                state.checkOllama()
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Suggestion Card
struct SuggestionCard: View {
    let suggestion: LLMSuggestion
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onApprove: () -> Void
    let onDismiss: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Button(action: onToggleSelection) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .foregroundColor(isSelected ? .accentColor : .secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                
                Image(systemName: "sparkles")
                    .foregroundColor(.accentColor)
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(suggestion.description)
                        .font(.headline)
                    
                    if !suggestion.affectedPaths.isEmpty {
                        let paths = suggestion.affectedPaths.prefix(3).map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
                        Text(paths + (suggestion.affectedPaths.count > 3 ? "..." : ""))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    
                    HStack {
                        Image(systemName: "arrow.right")
                        Text("Suggested: \(suggestion.suggestedAction)")
                    }
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .padding(.top, 4)
                }
                Spacer()
                
                // Confidence badge with warning for low confidence
                HStack(spacing: 4) {
                    if suggestion.confidence < 0.5 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.caption2)
                    }
                    Text(confidenceString)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(confidenceColor.opacity(0.2))
                        .foregroundColor(confidenceColor)
                        .cornerRadius(4)
                }
            }
            
            HStack {
                Spacer()
                Button("Dismiss") { onDismiss() }
                    .buttonStyle(.bordered)
                Button("Approve") { onApprove() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
        .padding(.vertical, 4)
    }
    
    private var confidenceString: String {
        if suggestion.confidence > 0.8 { return "High" }
        if suggestion.confidence > 0.5 { return "Medium" }
        return "Low confidence"
    }
    
    private var confidenceColor: Color {
        if suggestion.confidence > 0.8 { return .green }
        if suggestion.confidence > 0.5 { return .orange }
        return .red
    }
}

// MARK: - Helper Functions

func determineDestinationFolder(suggestion: LLMSuggestion, rootURL: URL) -> String {
    let actionStr = suggestion.suggestedAction.lowercased()
    let type = suggestion.type
    
    // First try to extract folder name from suggestedAction text using regex
    // Look for quoted strings: 'foldername' or "foldername"
    if let folderName = extractFolderName(from: actionStr) {
        return folderName
    }
    
    // Fallback: determine based on suggestion type
    switch type {
    case .groupByExtension:
        // Get most common extension from affectedPaths using frequency count
        let extensions = suggestion.affectedPaths
            .map { URL(fileURLWithPath: $0).pathExtension.lowercased() }
            .filter { !$0.isEmpty }
        
        if !extensions.isEmpty {
            // Find most common extension
            var counts: [String: Int] = [:]
            for ext in extensions {
                counts[ext, default: 0] += 1
            }
            if let mostCommon = counts.max(by: { $0.value < $1.value }) {
                return mostCommon.key
            }
        }
        return "by_extension"
        
    case .groupByNamePattern:
        // Find longest common prefix among filenames
        let names = suggestion.affectedPaths.map { URL(fileURLWithPath: $0).lastPathComponent }
        if let commonPrefix = findCommonPrefix(names: names) {
            let cleaned = commonPrefix
                .replacingOccurrences(of: "*", with: "")
                .replacingOccurrences(of: " ", with: "_")
                .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            if !cleaned.isEmpty {
                return cleaned
            }
        }
        return "grouped"
        
    case .groupOrphanFiles:
        return "orphaned_files"
        
    case .potentialVersions:
        return "versions"
        
    case .misplacedFiles:
        return "misplaced"
        
    case .largeFilesReview:
        return "large_files"
        
    @unknown default:
        return "ai_grouped"
    }
}

func extractFolderName(from text: String) -> String? {
    // Try single quotes first: Create folder 'zip'
    if let regex = try? NSRegularExpression(pattern: "'([^']+)'", options: []),
       let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
       let range = Range(match.range(at: 1), in: text) {
        let folder = String(text[range]).lowercased()
        return folder.isEmpty ? nil : folder
    }
    
    // Try double quotes: Create folder "zip"
    if let regex = try? NSRegularExpression(pattern: "\"([^\"]+)\"", options: []),
       let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
       let range = Range(match.range(at: 1), in: text) {
        let folder = String(text[range]).lowercased()
        return folder.isEmpty ? nil : folder
    }
    
    return nil
}

func findCommonPrefix(names: [String]) -> String? {
    guard !names.isEmpty else { return nil }
    
    let sorted = names.sorted()
    guard let first = sorted.first, let last = sorted.last else { return nil }
    
    var prefix = ""
    for (c1, c2) in zip(first, last) {
        if c1 == c2 {
            prefix.append(c1)
        } else {
            break
        }
    }
    
    // Remove trailing numbers/underscores/spaces
    while let lastChar = prefix.last, lastChar.isNumber || lastChar == "_" || lastChar == " " {
        prefix.removeLast()
    }
    
    return prefix.isEmpty ? nil : prefix
}
