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
    @Published var errorMessage: String?
    
    let engine = LLMEngine()
    
    func checkOllama() {
        Task {
            let available = await engine.isOllamaAvailable()
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
                        topItems.append(FolderTreeItem(
                            name: itemURL.lastPathComponent,
                            isDirectory: isDirectory,
                            sizeBytes: size,
                            fileCount: fileCount,
                            extension: isDirectory ? nil : itemURL.pathExtension,
                            modifiedDaysAgo: daysAgo
                        ))
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
        guard let actionPlan = appState.actionPlan else {
            // Need a plan to append to
            var actions: [PlannedAction] = []
            let plan = ActionPlan(actions: actions) // Need to resolve target files here
            // Note: The prompt requires files, we only have paths.
            // Converting paths to FileDescriptors requires hitting the disk.
            self.convertSuggestionToActionPlan(suggestion: suggestion, appState: appState)
            return
        }
        
        self.convertSuggestionToActionPlan(suggestion: suggestion, appState: appState)
    }
    
    private func convertSuggestionToActionPlan(suggestion: LLMSuggestion, appState: AppState) {
         Task.detached {
            var newActions: [PlannedAction] = []
            // Simplistic map: path string to Action
            for path in suggestion.affectedPaths {
                let url = URL(fileURLWithPath: path)
                
                // Construct a FileDescriptor
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                let fd = FileDescriptor(
                    fileURL: url,
                    fileName: url.lastPathComponent,
                    fileExtension: url.pathExtension,
                    fileSize: (attrs?[.size] as? Int64) ?? 0,
                    createdAt: (attrs?[.creationDate] as? Date) ?? Date(),
                    modifiedAt: (attrs?[.modificationDate] as? Date) ?? Date(),
                    isDirectory: (attrs?[.type] as? FileAttributeType) == .typeDirectory,
                    isSymlink: false,
                    permissionsReadable: true
                )
                
                // Parse "suggestedAction": either move or skip based on text
                // Since LLM returns text like "Move to Archive/", we resolve the root path
                var actionType: ActionType = .skip
                let actionStr = suggestion.suggestedAction.lowercased()
                
                if actionStr.contains("move to") || actionStr.contains("group") {
                    // Very rudimentary parsing to generate a destination
                    let words = suggestion.suggestedAction.split(separator: " ").map(String.init)
                    // Pick the last word if it looks like a path, else fallback
                    let destFolder = words.last?.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\"", with: "") ?? "AI_Grouped"
                    
                    // Put it in the selected Folder root
                    if let root = await appState.selectedFolderURL {
                        let destURL = root.appendingPathComponent(destFolder).appendingPathComponent(url.lastPathComponent)
                        actionType = .move(destination: destURL)
                    }
                } else if actionStr.contains("delete") || actionStr.contains("trash") || actionStr.contains("remove") {
                     actionType = .delete
                }
                
                let action = PlannedAction(
                    targetFile: fd,
                    actionType: actionType,
                    reason: "AI: \(suggestion.description)"
                )
                newActions.append(action)
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
                
                // Switch tab so user sees the newly populated Plan
                appState.selectedTab = .organize
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
                HStack {
                    Text("Ollama Model")
                    Spacer()
                    TextField("Model name", text: Binding(
                        get: { state.engine.selectedModel },
                        set: { state.engine.selectedModel = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                }
            }
            
            Section(header: Text("Suggestions").font(.headline).foregroundColor(.secondary)) {
                ForEach(state.suggestions) { suggestion in
                    SuggestionCard(suggestion: suggestion, onApprove: {
                        state.approve(suggestion: suggestion, appState: appState)
                    }, onDismiss: {
                        state.dismiss(suggestion: suggestion)
                    })
                }
            }
        }
        .listStyle(.inset)
    }
}

// MARK: - Suggestion Card
struct SuggestionCard: View {
    let suggestion: LLMSuggestion
    let onApprove: () -> Void
    let onDismiss: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
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
