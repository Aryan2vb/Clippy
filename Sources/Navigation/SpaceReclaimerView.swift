import SwiftUI
import ClippyCore
import ClippyEngine

// MARK: - Space Reclaimer Models

struct DependencyFolder: Identifiable {
    let id = UUID()
    let url: URL
    let projectName: String      // parent folder name
    let folderType: String       // "node_modules", ".venv" etc
    let sizeBytes: Int64         // calculated recursively
    let lastModified: Date       // of parent project folder
    var isSelected: Bool = true  // for batch delete
}

struct DependencyDeletionResult: Identifiable {
    let id = UUID()
    let folder: DependencyFolder
    let success: Bool
    let errorMessage: String?
}

// MARK: - Space Reclaimer State

@MainActor
class SpaceReclaimerState: ObservableObject {
    @Published var foundFolders: [DependencyFolder] = []
    @Published var isScanning = false
    @Published var isDeleting = false
    @Published var scanProgress: String = ""
    @Published var deletionResults: [DependencyDeletionResult] = []
    @Published var showResults = false
    
    let targetFolderNames: Set<String> = [
        "node_modules", ".venv", "venv", "env", "Pods", "__pycache__", ".gradle",
        ".tox", ".yarn", "dist", "build", ".next", "target", "vendor", ".bundle"
    ]
    
    var totalSelectedSize: Int64 {
        foundFolders.filter(\.isSelected).reduce(0) { $0 + $1.sizeBytes }
    }
    
    func selectAll() {
        for i in foundFolders.indices {
            foundFolders[i].isSelected = true
        }
    }
    
    func deselectAll() {
        for i in foundFolders.indices {
            foundFolders[i].isSelected = false
        }
    }
    
    func scan(rootURL: URL) {
        isScanning = true
        foundFolders = []
        deletionResults = []
        showResults = false
        scanProgress = "Starting scan..."
        
        Task.detached {
            var results: [DependencyFolder] = []
            let fileManager = FileManager.default
            
            // Limit depth to avoid infinite loops/excessive scanning
            let maxDepth = 10
            
            func scanDirectory(url: URL, depth: Int) {
                if depth > maxDepth { return }
                
                guard let enumerator = fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .nameKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles] // We check hidden files specifically if needed
                ) else { return }
                
                // Keep track of visited directories to limit depth calculation easily
                // For a simpler approach, we just use the enumerator.
            }
            let targetNames = self.targetFolderNames
            // For rigorous recursive scan targeting specific names without opening them
            var searchQueue: [(URL, Int)] = [(rootURL, 0)]
            
            while !searchQueue.isEmpty {
                let (currentURL, depth) = searchQueue.removeFirst()
                if depth > maxDepth { continue }
                
                let currentFileName = currentURL.lastPathComponent
                await MainActor.run {
                    self.scanProgress = "Scanning: \(currentFileName)"
                }
                
                do {
                    let contents = try fileManager.contentsOfDirectory(
                        at: currentURL,
                        includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
                    )
                    
                    for itemURL in contents {
                        var isDirectory: ObjCBool = false
                        if fileManager.fileExists(atPath: itemURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                            let folderName = itemURL.lastPathComponent
                            
                            if targetNames.contains(folderName) {
                                // Found a target! Calculate size.
                                let size = self.calculateDirectorySize(url: itemURL)
                                
                                // Get parent dir for project name & mod date
                                let parentURL = itemURL.deletingLastPathComponent()
                                let projectName = parentURL.lastPathComponent
                                let parentAttrs = try? fileManager.attributesOfItem(atPath: parentURL.path)
                                let modDate = (parentAttrs?[.modificationDate] as? Date) ?? Date()
                                
                                // Determine if it should be auto-selected (older than 7 days)
                                let daysSinceMod = Calendar.current.dateComponents([.day], from: modDate, to: Date()).day ?? 0
                                let isSelected = daysSinceMod > 7
                                
                                let depData = DependencyFolder(
                                    url: itemURL,
                                    projectName: projectName,
                                    folderType: folderName,
                                    sizeBytes: size,
                                    lastModified: modDate,
                                    isSelected: isSelected
                                )
                                results.append(depData)
                                
                                await MainActor.run {
                                    self.foundFolders.append(depData)
                                }
                                
                                // Do NOT search inside this dependency folder
                            } else {
                                // Not a target folder, add to search queue
                                searchQueue.append((itemURL, depth + 1))
                            }
                        }
                    }
                } catch {
                    // Ignore read errors for inaccessible folders
                }
            }
            
            await MainActor.run {
                self.isScanning = false
            }
        }
    }
    
    nonisolated private func calculateDirectorySize(url: URL) -> Int64 {
        let fileManager = FileManager.default
        var totalSize: Int64 = 0
        
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [] // dive into everything
        ) else { return 0 }
        
        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                if let fileSize = resourceValues.fileSize {
                    totalSize += Int64(fileSize)
                }
            } catch {
                // ignore
            }
        }
        
        return totalSize
    }
    
    func deleteSelected(appState: AppState) {
        let selectedFolders = foundFolders.filter(\.isSelected)
        guard !selectedFolders.isEmpty else { return }
        
        isDeleting = true
        deletionResults = []
        
        Task.detached {
            let fileManager = FileManager.default
            var localResults: [DependencyDeletionResult] = []
            var logEntries: [ExecutionLog.Entry] = []
            
            for folder in selectedFolders {
                var trashURL: NSURL?
                do {
                    try fileManager.trashItem(at: folder.url, resultingItemURL: &trashURL)
                    localResults.append(DependencyDeletionResult(folder: folder, success: true, errorMessage: nil))
                    
                    logEntries.append(ExecutionLog.Entry(
                        actionId: folder.id,
                        sourceURL: folder.url,
                        destinationURL: trashURL as URL?,
                        outcome: .success,
                        message: "Moved to Trash"
                    ))
                } catch {
                    localResults.append(DependencyDeletionResult(folder: folder, success: false, errorMessage: error.localizedDescription))
                    logEntries.append(ExecutionLog.Entry(
                        actionId: folder.id,
                        sourceURL: folder.url,
                        destinationURL: nil,
                        outcome: .failed,
                        message: error.localizedDescription
                    ))
                }
            }
            
            // Create a fake execution log to pass to HistoryManager so it can be undone
            let log = ExecutionLog(planId: UUID(), timestamp: Date(), entries: logEntries)
            
            let finalResults = localResults
            await MainActor.run {
                self.deletionResults = finalResults
                self.showResults = true
                self.isDeleting = false
                
                // Update history
                if let rootURL = appState.selectedFolderURL {
                    appState.historyManager.recordSession(from: log, folderPath: rootURL.path)
                }
                
                // Remove successful deletions from foundFolders
                let successfulIDs = finalResults.filter(\.success).map(\.folder.id)
                self.foundFolders.removeAll { successfulIDs.contains($0.id) }
            }
        }
    }
}

// MARK: - Space Reclaimer View

struct SpaceReclaimerView: View {
    @ObservedObject var appState: AppState
    @StateObject private var state = SpaceReclaimerState()
    @State private var showingConfirmDelete = false
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            
            if appState.selectedFolderURL == nil {
                noFolderView
            } else if state.isScanning {
                scanningView
            } else if state.showResults {
                resultsView
            } else if state.foundFolders.isEmpty {
                emptyStateView
            } else {
                contentView
            }
            
            if !state.foundFolders.isEmpty && !state.isScanning && !state.showResults {
                Divider()
                footerView
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .alert("Complete Clean", isPresented: $showingConfirmDelete) {
            Button("Cancel", role: .cancel) { }
            Button("Delete Selected", role: .destructive) {
                state.deleteSelected(appState: appState)
            }
        } message: {
            let count = state.foundFolders.filter(\.isSelected).count
            let size = ByteCountFormatter.string(fromByteCount: state.totalSelectedSize, countStyle: .file)
            Text("Delete \(count) dependency folders? (\(size)) This will move them to Trash.")
        }
    }
    
    // MARK: - Subviews
    
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Space Reclaimer").font(.title2).fontWeight(.semibold)
                Text("Find and safely remove heavy dependency folders like node_modules.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            
            if appState.selectedFolderURL != nil && !state.isScanning {
                Button {
                    if let url = appState.selectedFolderURL {
                        state.scan(rootURL: url)
                    }
                } label: {
                    Label(state.foundFolders.isEmpty ? "Find Dependencies" : "Rescan", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding(20)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private var noFolderView: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
            Text("No Folder Selected")
                .font(.title3).fontWeight(.medium)
            Text("Select a folder in the organize tab first to scan for dependencies.")
                .font(.body).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var scanningView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)
            Text("Scanning for Dependency Folders...")
                .font(.headline)
            Text(state.scanProgress)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 48))
                .foregroundColor(.green.opacity(0.8))
            Text("All Clean")
                .font(.title3).fontWeight(.medium)
            Text("No dependency folders found in this directory.")
                .font(.body).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var resultsView: some View {
        VStack {
            HStack {
                Text("Deletion Results")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    state.showResults = false
                }
                .buttonStyle(.bordered)
            }
            .padding()
            
            List(state.deletionResults) { result in
                HStack {
                    Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(result.success ? .green : .red)
                    Text("\(result.folder.projectName) / \(result.folder.folderType)")
                    Spacer()
                    if let error = result.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
        }
    }
    
    private var contentView: some View {
        List {
            let totalFoundSize = state.foundFolders.reduce(0) { $0 + $1.sizeBytes }
            
            Section(header: HStack {
                Text("🗂 Dependency Folders Found")
                Spacer()
                Text("Total: \(ByteCountFormatter.string(fromByteCount: totalFoundSize, countStyle: .file))")
            }.font(.headline).foregroundColor(.secondary)) {
                
                // Group by project name for nicer display
                let grouped = Dictionary(grouping: state.foundFolders) { $0.projectName }
                let sortedProjects = grouped.keys.sorted()
                
                ForEach(sortedProjects, id: \.self) { project in
                    let projectFolders = grouped[project]!
                    ForEach(projectFolders) { folder in
                        DependencyRow(
                            folder: folder,
                            isOn: Binding(
                                get: { folder.isSelected },
                                set: { newValue in
                                    if let index = state.foundFolders.firstIndex(where: { $0.id == folder.id }) {
                                        state.foundFolders[index].isSelected = newValue
                                    }
                                }
                            )
                        )
                    }
                }
            }
        }
        .listStyle(.inset)
    }
    
    private var footerView: some View {
        HStack {
            let selectedSize = ByteCountFormatter.string(fromByteCount: state.totalSelectedSize, countStyle: .file)
            Text("Selected: \(selectedSize)")
                .font(.headline)
            
            Spacer()
            
            Button("Select All") { state.selectAll() }
                .buttonStyle(.borderless)
                .controlSize(.small)
            
            Text("|").foregroundColor(.secondary)
            
            Button("Deselect All") { state.deselectAll() }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .padding(.trailing, 16)
            
            Button {
                showingConfirmDelete = true
            } label: {
                HStack {
                    Text("Delete Selected")
                    Image(systemName: "arrow.right")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(state.totalSelectedSize == 0 || state.isDeleting)
        }
        .padding(16)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Dependency Row
struct DependencyRow: View {
    let folder: DependencyFolder
    @Binding var isOn: Bool
    
    var body: some View {
        HStack {
            Toggle("", isOn: $isOn)
                .labelsHidden()
            
            VStack(alignment: .leading) {
                Text("\(folder.projectName) / \(folder.folderType)")
                    .fontWeight(.medium)
                Text(folder.url.path)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            
            Spacer()
            
            VStack(alignment: .trailing) {
                Text(ByteCountFormatter.string(fromByteCount: folder.sizeBytes, countStyle: .file))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                HStack(spacing: 4) {
                    if isRecent {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                            .font(.caption2)
                    }
                    Text(timeAgo)
                        .font(.caption)
                        .foregroundColor(isRecent ? .orange : .secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    private var isRecent: Bool {
        let days = Calendar.current.dateComponents([.day], from: folder.lastModified, to: Date()).day ?? 0
        return days < 7
    }
    
    private var timeAgo: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: folder.lastModified, relativeTo: Date())
    }
}
