import SwiftUI
import UniformTypeIdentifiers
import ClippyCore
import ClippyEngine
import CryptoKit

// MARK: - App State

@MainActor
class AppState: ObservableObject, ScanBridgeDelegate {
    @Published var rules: [Rule] = [] {
        didSet {
            saveRules()
        }
    }
    @Published var selectedFolderURL: URL?
    @Published var scanResult: ScanResult?
    @Published var actionPlan: ActionPlan?
    @Published var executionLog: ExecutionLog?
    @Published var stalenessState: ScanStalenessState?
    @Published var cancellationMessage: String?
    
    @Published var isScanning = false
    @Published var isExecuting = false
    @Published var selectedTab: SidebarTab = .organize
    
    // Cancellation support
    @Published var scanProgress: ScanProgress?
    
    // Duplicate detection
    @Published var duplicateGroups: [[FileDescriptor]] = []
    @Published var showDuplicates = false
    
    // Rule filtering
    @Published var selectedRuleGroup: String?
    @Published var ruleSearchText: String = ""
    
    // Folder exclusions (user-defined)
    @Published var userExcludedFolders: [String] = [] {
        didSet {
            saveExcludedFolders()
        }
    }
    
    let scanner = FileScanner()
    let planner = Planner()
    let executor: ExecutionEngine
    let undoEngine = UndoEngine()
    let scanBridge = ScanBridge()
    let historyManager = HistoryManager()
    let searchManager = SearchManager()
    
    private let fileManager = FileManager.default
    private let rulesFileName = "rules.json"
    private let excludedFoldersKey = "userExcludedFolders"
    
    /// Computed property for filtered rules
    var filteredRules: [Rule] {
        rules.filter { rule in
            // Filter by group
            if let selectedGroup = selectedRuleGroup {
                if rule.group != selectedGroup {
                    return false
                }
            }
            
            // Filter by search text
            if !ruleSearchText.isEmpty {
                let searchLower = ruleSearchText.lowercased()
                let matchesName = rule.name.lowercased().contains(searchLower)
                let matchesDesc = rule.description.lowercased().contains(searchLower)
                let matchesTags = rule.tags.contains { $0.lowercased().contains(searchLower) }
                if !(matchesName || matchesDesc || matchesTags) {
                    return false
                }
            }
            
            return true
        }
    }
    
    /// All unique rule groups
    var ruleGroups: [String] {
        Array(Set(rules.compactMap { $0.group })).sorted()
    }
    
    /// Cancel the current scan operation
    func cancelScan() {
        Task {
            await scanner.cancel()
        }
    }
    
    /// Disable all rules (single save)
    func disableAllRules() {
        var updated = rules
        for i in updated.indices {
            updated[i] = updated[i].withEnabled(false)
        }
        rules = updated
    }
    
    /// Enable all rules (single save)
    func enableAllRules() {
        var updated = rules
        for i in updated.indices {
            updated[i] = updated[i].withEnabled(true)
        }
        rules = updated
    }
    
    // MARK: - Workflow Functions (Single Source of Truth)
    
    func startScan() {
        guard let url = selectedFolderURL else { return }
        isScanning = true
        scanResult = nil
        actionPlan = nil
        executionLog = nil
        scanProgress = nil
        cancellationMessage = nil
        
        // Set excluded folders before scanning
        let excludedSet = Set(userExcludedFolders)
        
        Task {
            await scanner.setExcludedFolders(excludedSet)
            let result = await scanner.scan(folderURL: url) { progress in
                Task { @MainActor in
                    self.scanProgress = progress
                }
            }
            await MainActor.run {
                if result.wasCancelled {
                    self.scanResult = nil
                    self.cancellationMessage = "Scan was cancelled. No files were loaded."
                } else {
                    self.scanResult = result
                    self.cancellationMessage = nil
                    self.scanBridge.markScanCompleted(for: url)
                    self.stalenessState = self.scanBridge.staleness(for: url)
                    self.searchManager.updateData(files: result.files, rules: self.rules, history: self.historyManager.sessions)
                    Task { await self.detectDuplicates(from: result.files) }
                }
                self.isScanning = false
                self.scanProgress = nil
            }
        }
    }
    
    func createPlan() {
        guard let result = scanResult else { return }
        let enabledRules = rules.filter(\.isEnabled)
        let plan = planner.plan(files: result.files, rules: enabledRules)
        actionPlan = plan
    }
    
    func executePlan() {
        guard let plan = actionPlan else { return }
        guard !plan.actions.contains(where: { $0.isConflict }) else { return }
        isExecuting = true
        let executor = self.executor
        let folderPath = selectedFolderURL?.path ?? "Unknown"
        Task.detached(priority: .userInitiated) { [self] in // Changed from [weak self] to [self]
            let log = executor.execute(plan: plan)
            await MainActor.run {
                self.executionLog = log
                self.actionPlan = nil
                self.isExecuting = false
                self.historyManager.recordSession(from: log, folderPath: folderPath)
            }
        }
    }
    
    func performUndo() {
        guard let log = executionLog else { return }
        isExecuting = true
        let undoEngine = self.undoEngine
        Task.detached(priority: .userInitiated) {
            let _ = undoEngine.undo(log: log)
            await MainActor.run {
                self.executionLog = nil
                self.scanResult = nil
                self.isExecuting = false
            }
        }
    }
    
    private func detectDuplicates(from files: [FileDescriptor]) async {
        let sizeGroups = Dictionary(grouping: files) { $0.fileSize }
        var duplicates: [[FileDescriptor]] = []
        for (_, group) in sizeGroups where group.count > 1 {
            if group.count > 1 {
                let hashGroups = await hashBasedGrouping(files: group)
                for (_, sameHashFiles) in hashGroups where sameHashFiles.count > 1 {
                    duplicates.append(sameHashFiles)
                }
            }
        }
        await MainActor.run {
            self.duplicateGroups = duplicates
        }
    }
    
    private func hashBasedGrouping(files: [FileDescriptor]) async -> [String: [FileDescriptor]] {
        var groups: [String: [FileDescriptor]] = [:]
        for file in files {
            if let hash = computeFileHash(file.fileURL) {
                groups[hash, default: []].append(file)
            }
        }
        return groups
    }
    
    private func computeFileHash(_ url: URL) -> String? {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fileHandle.close() }
        let bufferSize = 1024 * 1024
        var hasher = CryptoKit.SHA256()
        while let data = try? fileHandle.read(upToCount: bufferSize), !data.isEmpty {
            hasher.update(data: data)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    init() {
        // Configure sandbox boundaries for file operations
        let home = NSHomeDirectory()
        let allowedPaths = [
            home,
            home + "/Documents",
            home + "/Downloads",
            home + "/Desktop",
            home + "/Pictures",
            home + "/Movies",
            home + "/Music"
        ]
        self.executor = ExecutionEngine(allowedSandboxPaths: allowedPaths)
        
        // Connect ScanBridge delegate
        self.scanBridge.delegate = self
        
        // Load saved rules or fall back to defaults
        loadRules()
        
        // Load saved excluded folders
        loadExcludedFolders()
    }
    
    // MARK: - ScanBridgeDelegate
    
    nonisolated func scanBridge(_ bridge: ScanBridge, suggestsRescan suggestion: ScanSuggestion) {
        Task { @MainActor in
            self.stalenessState = bridge.staleness(for: suggestion.rootURL)
        }
    }
    
    private var rulesFileURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("Clippy", isDirectory: true)
        
        if !fileManager.fileExists(atPath: appFolder.path) {
            try? fileManager.createDirectory(at: appFolder, withIntermediateDirectories: true)
        }
        
        return appFolder.appendingPathComponent(rulesFileName)
    }
    
    private func loadRules() {
        guard fileManager.fileExists(atPath: rulesFileURL.path) else {
            loadDefaultRules()
            return
        }
        
        do {
            let data = try Data(contentsOf: rulesFileURL)
            let decoder = JSONDecoder()
            rules = try decoder.decode([Rule].self, from: data)
        } catch {
            loadDefaultRules()
        }
    }
    
    private func saveRules() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(rules)
            try data.write(to: rulesFileURL, options: .atomic)
        } catch {
            // Silent fail - rules will be re-saved on next change
        }
    }
    
    private func loadExcludedFolders() {
        if let saved = UserDefaults.standard.array(forKey: excludedFoldersKey) as? [String] {
            userExcludedFolders = saved
        }
    }
    
    private func saveExcludedFolders() {
        UserDefaults.standard.set(userExcludedFolders, forKey: excludedFoldersKey)
    }
    
    private func loadDefaultRules() {
        let home = NSHomeDirectory()
        
        rules = [
            // MARK: - Documents
            Rule(
                name: "Archive PDFs",
                description: "Move PDF files to the Archive folder",
                conditions: [.fileExtension(is: "pdf")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Documents/Archive/PDFs")),
                group: "Documents",
                tags: ["documents", "pdf", "archive"]
            ),
            Rule(
                name: "Organize CSV Files",
                description: "Move CSV data files to Data folder",
                conditions: [.fileExtension(is: "csv")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Documents/Data/CSV")),
                group: "Documents",
                tags: ["data", "csv"]
            ),
            Rule(
                name: "Organize Excel Files",
                description: "Move Excel spreadsheets to Spreadsheets folder",
                conditions: [.fileExtension(is: "xlsx")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Documents/Spreadsheets")),
                group: "Documents",
                tags: ["spreadsheet", "excel", "office"]
            ),
            Rule(
                name: "Organize Word Documents",
                description: "Move Word documents to Documents folder",
                conditions: [.fileExtension(is: "docx")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Documents/Word")),
                group: "Documents",
                tags: ["word", "office", "documents"]
            ),
            
            // MARK: - Images
            Rule(
                name: "Organize Screenshots",
                description: "Move screenshots to Screenshots folder",
                conditions: [.fileName(contains: "Screenshot")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Pictures/Screenshots")),
                group: "Images",
                tags: ["screenshot", "images"]
            ),
            Rule(
                name: "Organize JPG Photos",
                description: "Move JPG images to Photos folder",
                conditions: [.fileExtension(is: "jpg")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Pictures/Photos/JPG")),
                group: "Images",
                tags: ["photos", "jpg", "images"]
            ),
            Rule(
                name: "Organize JPEG Photos",
                description: "Move JPEG images to Photos folder",
                conditions: [.fileExtension(is: "jpeg")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Pictures/Photos/JPG")),
                group: "Images",
                tags: ["photos", "jpeg", "images"]
            ),
            Rule(
                name: "Organize PNG Images",
                description: "Move PNG images to Pictures folder",
                conditions: [.fileExtension(is: "png")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Pictures/PNG")),
                group: "Images",
                tags: ["images", "png"]
            ),
            Rule(
                name: "Organize HEIC Photos",
                description: "Move HEIC photos to Photos folder",
                conditions: [.fileExtension(is: "heic")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Pictures/Photos/HEIC")),
                group: "Images",
                tags: ["photos", "heic", "images"]
            ),
            Rule(
                name: "Organize GIF Images",
                description: "Move GIF files to GIFs folder",
                conditions: [.fileExtension(is: "gif")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Pictures/GIFs"))
            ),
            
            // MARK: - RAW Photos
            Rule(
                name: "Organize Sony RAW (ARW)",
                description: "Move Sony ARW raw files to RAW folder",
                conditions: [.fileExtension(is: "arw")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Pictures/RAW/Sony"))
            ),
            Rule(
                name: "Organize Canon RAW (CR2)",
                description: "Move Canon CR2 raw files to RAW folder",
                conditions: [.fileExtension(is: "cr2")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Pictures/RAW/Canon"))
            ),
            Rule(
                name: "Organize Nikon RAW (NEF)",
                description: "Move Nikon NEF raw files to RAW folder",
                conditions: [.fileExtension(is: "nef")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Pictures/RAW/Nikon"))
            ),
            Rule(
                name: "Organize DNG Files",
                description: "Move DNG raw files to RAW folder",
                conditions: [.fileExtension(is: "dng")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Pictures/RAW/DNG"))
            ),
            
            // MARK: - Code & Development
            Rule(
                name: "Organize Jupyter Notebooks",
                description: "Move Jupyter notebooks to Notebooks folder",
                conditions: [.fileExtension(is: "ipynb")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Documents/Code/Notebooks"))
            ),
            Rule(
                name: "Organize Python Files",
                description: "Move Python scripts to Code folder",
                conditions: [.fileExtension(is: "py")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Documents/Code/Python")),
                isEnabled: false
            ),
            Rule(
                name: "Organize JavaScript Files",
                description: "Move JavaScript files to Code folder",
                conditions: [.fileExtension(is: "js")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Documents/Code/JavaScript")),
                isEnabled: false
            ),
            Rule(
                name: "Organize Swift Files",
                description: "Move Swift files to Code folder",
                conditions: [.fileExtension(is: "swift")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Documents/Code/Swift")),
                isEnabled: false
            ),
            Rule(
                name: "Organize JSON Files",
                description: "Move JSON files to Data folder",
                conditions: [.fileExtension(is: "json")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Documents/Data/JSON")),
                isEnabled: false
            ),
            
            // MARK: - Videos
            Rule(
                name: "Organize MP4 Videos",
                description: "Move MP4 videos to Videos folder",
                conditions: [.fileExtension(is: "mp4")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Movies/Videos"))
            ),
            Rule(
                name: "Organize MOV Videos",
                description: "Move MOV videos to Videos folder",
                conditions: [.fileExtension(is: "mov")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Movies/Videos"))
            ),
            Rule(
                name: "Organize MKV Videos",
                description: "Move MKV videos to Videos folder",
                conditions: [.fileExtension(is: "mkv")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Movies/Videos"))
            ),
            Rule(
                name: "Organize AVI Videos",
                description: "Move AVI videos to Videos folder",
                conditions: [.fileExtension(is: "avi")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Movies/Videos"))
            ),
            
            // MARK: - Audio
            Rule(
                name: "Organize MP3 Music",
                description: "Move MP3 audio files to Music folder",
                conditions: [.fileExtension(is: "mp3")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Music/MP3"))
            ),
            Rule(
                name: "Organize WAV Audio",
                description: "Move WAV audio files to Music folder",
                conditions: [.fileExtension(is: "wav")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Music/WAV"))
            ),
            Rule(
                name: "Organize FLAC Audio",
                description: "Move FLAC audio files to Music folder",
                conditions: [.fileExtension(is: "flac")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Music/FLAC"))
            ),
            Rule(
                name: "Organize M4A Audio",
                description: "Move M4A audio files to Music folder",
                conditions: [.fileExtension(is: "m4a")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Music/M4A"))
            ),
            
            // MARK: - Archives
            Rule(
                name: "Organize ZIP Archives",
                description: "Move ZIP files to Archives folder",
                conditions: [.fileExtension(is: "zip")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Documents/Archives"))
            ),
            Rule(
                name: "Organize RAR Archives",
                description: "Move RAR files to Archives folder",
                conditions: [.fileExtension(is: "rar")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Documents/Archives"))
            ),
            Rule(
                name: "Organize 7Z Archives",
                description: "Move 7Z files to Archives folder",
                conditions: [.fileExtension(is: "7z")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Documents/Archives"))
            ),
            Rule(
                name: "Organize TAR.GZ Archives",
                description: "Move tar.gz files to Archives folder",
                conditions: [.fileExtension(is: "gz")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Documents/Archives"))
            ),
            Rule(
                name: "Organize DMG Files",
                description: "Move disk images to Installers folder",
                conditions: [.fileExtension(is: "dmg")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Documents/Installers"))
            ),
            Rule(
                name: "Organize PKG Files",
                description: "Move package installers to Installers folder",
                conditions: [.fileExtension(is: "pkg")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Documents/Installers"))
            ),
            
            // MARK: - Special Rules
            Rule(
                name: "Clean Large Downloads",
                description: "Move files larger than 100MB to a review folder",
                conditions: [.fileSize(largerThan: 100_000_000)],
                outcome: .move(to: URL(fileURLWithPath: home + "/Documents/LargeFiles")),
                isEnabled: false
            ),
            Rule(
                name: "Organize Text Files",
                description: "Move text files to Notes folder",
                conditions: [.fileExtension(is: "txt")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Documents/Notes")),
                isEnabled: false
            ),
            Rule(
                name: "Organize Markdown Files",
                description: "Move markdown files to Notes folder",
                conditions: [.fileExtension(is: "md")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Documents/Notes")),
                isEnabled: false
            ),
            Rule(
                name: "Organize Log Files",
                description: "Move log files to Logs folder",
                conditions: [.fileExtension(is: "log")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Documents/Logs")),
                isEnabled: false
            ),
            Rule(
                name: "Organize SQL Files",
                description: "Move SQL files to Database folder",
                conditions: [.fileExtension(is: "sql")],
                outcome: .move(to: URL(fileURLWithPath: home + "/Documents/Code/Database")),
                isEnabled: false
            ),
            
            // MARK: - Junk Cleanup
            Rule(
                name: "Remove .DS_Store",
                description: "macOS metadata files — safe to delete",
                conditions: [.fileNameExact(is: ".DS_Store")],
                outcome: .delete,
                isEnabled: true,
                group: "Junk Cleanup",
                tags: ["junk", "macOS", "metadata"]
            ),
            Rule(
                name: "Remove Thumbs.db",
                description: "Windows thumbnail cache — safe to delete on Mac",
                conditions: [.fileNameExact(is: "Thumbs.db")],
                outcome: .delete,
                isEnabled: true,
                group: "Junk Cleanup",
                tags: ["junk", "windows", "cache"]
            ),
            Rule(
                name: "Remove .localized files",
                description: "Empty localization marker files",
                conditions: [.fileNameExact(is: ".localized")],
                outcome: .delete,
                isEnabled: true,
                group: "Junk Cleanup",
                tags: ["junk", "localization"]
            ),
            Rule(
                name: "Remove Office temp files",
                description: "Temporary files created by Microsoft Office",
                conditions: [.fileNamePrefix(startsWith: "~$")],
                outcome: .delete,
                isEnabled: true,
                group: "Junk Cleanup",
                tags: ["junk", "office", "temp"]
            ),
            Rule(
                name: "Remove .tmp files",
                description: "Temporary files safe to delete",
                conditions: [.fileExtension(is: "tmp")],
                outcome: .delete,
                isEnabled: true,
                group: "Junk Cleanup",
                tags: ["junk", "temp"]
            ),
            Rule(
                name: "Archive old log files",
                description: "Log files not modified in 30 days",
                conditions: [
                    .fileExtension(is: "log"),
                    .modifiedBefore(date: Date().addingTimeInterval(-30 * 24 * 60 * 60))
                ],
                outcome: .move(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("LogsArchive")),
                isEnabled: false,
                group: "Junk Cleanup",
                tags: ["log", "archive", "old"]
            )
        ]
    }
}

// MARK: - Main Content View

struct ContentView: View {
    @StateObject private var appState = AppState()
    
    var body: some View {
        NavigationSplitView {
            SidebarView(appState: appState)
        } detail: {
            switch appState.selectedTab {
            case .organize:
                OrganizeView(appState: appState)
            case .spaceReclaimer:
                SpaceReclaimerView(appState: appState)
            case .aiSuggestions:
                SuggestionsView(appState: appState)
            case .rules:
                RulesView(appState: appState)
            case .history:
                HistoryView(appState: appState)
            case .search:
                GlobalSearchView(appState: appState)
            case .statistics:
                StatisticsDashboardView(appState: appState)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        List(SidebarTab.allCases, id: \.self, selection: $appState.selectedTab) { tab in
            Label(tab.title, systemImage: tab.icon)
                .tag(tab)
        }
        .disabled(appState.isExecuting)
        .listStyle(.sidebar)
        .frame(minWidth: 200)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: DesignSystem.Spacing.md) {
                Divider()
                
                if let folder = appState.selectedFolderURL {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Text(folder.lastPathComponent)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            .background(DesignSystem.Colors.backgroundPrimary)
        }
    }
}



// MARK: - History View

struct HistoryView: View {
    @ObservedObject var appState: AppState
    @State private var showClearConfirmation = false
    @State private var expandedSessions: Set<UUID> = []
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HistoryHeaderView(
                appState: appState,
                showClearConfirmation: $showClearConfirmation
            )
            
            Divider()
            
            // Content
            if appState.historyManager.sessions.isEmpty {
                HistoryEmptyStateView()
            } else {
                HistoryListView(
                    appState: appState,
                    expandedSessions: $expandedSessions
                )
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .alert(UICopy.History.clearConfirmTitle, isPresented: $showClearConfirmation) {
            Button(UICopy.History.cancelButton, role: .cancel) { }
            Button(UICopy.History.clearConfirmButton, role: .destructive) {
                appState.historyManager.clearHistory()
            }
        } message: {
            Text(UICopy.History.clearConfirmMessage)
        }
    }
}

struct HistoryHeaderView: View {
    @ObservedObject var appState: AppState
    @Binding var showClearConfirmation: Bool
    
    var body: some View {
        HStack(spacing: DesignSystem.Spacing.xl) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("History")
                    .font(DesignSystem.Typography.title1)
                    .foregroundColor(.primary)
                
                Text("View and undo past file operations")
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if !appState.historyManager.sessions.isEmpty {
                HStack(spacing: DesignSystem.Spacing.md) {
                    ModernQuickStat(
                        value: "\(appState.historyManager.sessions.count)",
                        label: "sessions",
                        icon: "clock.fill",
                        color: DesignSystem.Colors.accentOrange
                    )
                    
                    ModernQuickStat(
                        value: "\(totalItems)",
                        label: "files processed",
                        icon: "doc.fill",
                        color: DesignSystem.Colors.accentBlue
                    )
                    
                    Button(UICopy.History.clearAllButton) {
                        showClearConfirmation = true
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .foregroundColor(.red)
                }
            }
        }
        .padding(DesignSystem.Spacing.xl)
        .background(DesignSystem.Colors.backgroundPrimary)
    }
    
    private var totalItems: Int {
        appState.historyManager.sessions.reduce(0) { $0 + $1.items.count }
    }
}

struct HistoryEmptyStateView: View {
    var body: some View {
        ModernEmptyState(
            icon: "clock.arrow.circlepath",
            title: "No History Yet",
            description: "Actions you perform will appear here. You'll see what happened, when, and where files are now.",
            color: DesignSystem.Colors.accentOrange
        )
    }
}

struct HistoryListView: View {
    @ObservedObject var appState: AppState
    @Binding var expandedSessions: Set<UUID>
    @State private var showUndoConfirmation = false
    @State private var sessionToUndo: HistorySession?
    @State private var undoResult: HistoryManager.UndoResult?
    @State private var showUndoResult = false
    
    var body: some View {
        List {
            ForEach(appState.historyManager.sessions) { session in
                HistorySessionView(
                    session: session,
                    isExpanded: expandedSessions.contains(session.id),
                    historyManager: appState.historyManager,
                    onToggle: {
                        if expandedSessions.contains(session.id) {
                            expandedSessions.remove(session.id)
                        } else {
                            expandedSessions.insert(session.id)
                        }
                    },
                    onDelete: {
                        appState.historyManager.deleteSession(session)
                    },
                    onUndo: {
                        sessionToUndo = session
                        showUndoConfirmation = true
                    }
                )
            }
        }
        .listStyle(.inset)
        .alert(UICopy.History.undoConfirmTitle, isPresented: $showUndoConfirmation) {
            Button(UICopy.History.cancelButton, role: .cancel) {
                sessionToUndo = nil
            }
            Button(UICopy.History.undoConfirmButton) {
                if let session = sessionToUndo {
                    undoResult = appState.historyManager.undoSession(session)
                    showUndoResult = true
                }
                sessionToUndo = nil
            }
        } message: {
            Text(UICopy.History.undoConfirmMessage)
        }
        .sheet(isPresented: $showUndoResult) {
            if let result = undoResult {
                UndoResultView(result: result, onDismiss: {
                    showUndoResult = false
                    undoResult = nil
                })
            }
        }
    }
}

// MARK: - Undo Result View

struct UndoResultView: View {
    let result: HistoryManager.UndoResult
    let onDismiss: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: result.isFullyRestored ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(result.isFullyRestored ? .green : .orange)
                    .font(.title2)
                
                Text(UICopy.History.undoResultTitle)
                    .font(.headline)
                
                Spacer()
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Summary
            VStack(alignment: .leading, spacing: 12) {
                Text(result.isFullyRestored ? UICopy.History.undoSuccessMessage : UICopy.History.undoPartialMessage)
                    .font(.body)
                
                // Stats
                HStack(spacing: 16) {
                    if result.restoredCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("\(result.restoredCount) \(UICopy.History.undoRestored.lowercased())")
                        }
                    }
                    if result.skippedCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.gray)
                            Text("\(result.skippedCount) \(UICopy.History.undoSkipped.lowercased())")
                        }
                    }
                    if result.failedCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                            Text("\(result.failedCount) \(UICopy.History.undoFailed.lowercased())")
                        }
                    }
                }
                .font(.caption)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Divider()
            
            // Details list
            List {
                ForEach(Array(result.details.enumerated()), id: \.offset) { _, detail in
                    HStack(spacing: 12) {
                        outcomeIcon(for: detail.outcome)
                            .frame(width: 20)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(detail.fileName)
                                .fontWeight(.medium)
                            Text(detail.message)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.inset)
            
            Divider()
            
            // Footer
            HStack {
                Spacer()
                Button(UICopy.History.okButton) {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 500, height: 400)
    }
    
    @ViewBuilder
    private func outcomeIcon(for outcome: HistoryManager.UndoOutcome) -> some View {
        switch outcome {
        case .restored:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .skipped:
            Image(systemName: "minus.circle.fill")
                .foregroundColor(.gray)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        }
    }
}

struct HistorySessionView: View {
    let session: HistorySession
    let isExpanded: Bool
    let historyManager: HistoryManager
    let onToggle: () -> Void
    let onDelete: () -> Void
    let onUndo: () -> Void
    
    private var canUndo: Bool {
        // Can undo if there are any successful items
        session.successCount > 0
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Session header
            HStack(spacing: 12) {
                Button(action: onToggle) {
                    HStack(spacing: 12) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .foregroundColor(.secondary)
                            .frame(width: 16)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(session.formattedDate)
                                    .font(.headline)
                                
                                Text(UICopy.History.actionAt(time: session.formattedTime))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            HStack(spacing: 8) {
                                Text("\(session.items.count) \(UICopy.History.filesProcessed)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Text("•")
                                    .foregroundColor(.secondary)
                                
                                Text(UICopy.History.sessionSummary(
                                    success: session.successCount,
                                    failed: session.failedCount,
                                    skipped: session.skippedCount
                                ))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            }
                            
                            Text(session.folderPath)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                // Summary badges
                HStack(spacing: 6) {
                    if session.successCount > 0 {
                        MiniStatusBadge(count: session.successCount, color: .green)
                    }
                    if session.failedCount > 0 {
                        MiniStatusBadge(count: session.failedCount, color: .red)
                    }
                    if session.skippedCount > 0 {
                        MiniStatusBadge(count: session.skippedCount, color: .gray)
                    }
                }
                
                // Undo button
                if canUndo {
                    Button {
                        onUndo()
                    } label: {
                        Label(UICopy.History.undoSessionButton, systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 8)
            .contextMenu {
                if canUndo {
                    Button {
                        onUndo()
                    } label: {
                        Label(UICopy.History.undoSessionButton, systemImage: "arrow.uturn.backward")
                    }
                }
                
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label(UICopy.History.deleteSession, systemImage: "trash")
                }
            }
            
            // Expanded items
            if isExpanded {
                Divider()
                    .padding(.leading, 28)
                
                ForEach(session.items) { item in
                    HistoryItemRowView(
                        item: item,
                        session: session,
                        historyManager: historyManager,
                        onUndo: onUndo
                    )
                    .padding(.leading, 28)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct MiniStatusBadge: View {
    let count: Int
    let color: Color
    
    var body: some View {
        Text("\(count)")
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(4)
    }
}

struct HistoryItemRowView: View {
    let item: HistoryItem
    let session: HistorySession
    let historyManager: HistoryManager
    let onUndo: () -> Void
    
    @State private var isHovering = false
    @State private var showUndoConfirmation = false
    @State private var undoResult: HistoryManager.UndoItemResult?
    @State private var showUndoResult = false
    
    private var canUndo: Bool {
        item.outcome == .success && item.actionType != .skipped
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Main row
            HStack(spacing: 12) {
                // Action icon
                Image(systemName: item.actionType.icon)
                    .foregroundColor(iconColor)
                    .frame(width: 24)
                
                // File info
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.fileName)
                            .fontWeight(.medium)
                        
                        Text(item.actionType.rawValue)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(iconColor.opacity(0.15))
                            .foregroundColor(iconColor)
                            .cornerRadius(4)
                        
                        // Undo badge if already undone
                        if item.outcome == .skipped && item.message?.contains("Undone") == true {
                            Text("Undone")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15))
                                .foregroundColor(.orange)
                                .cornerRadius(4)
                        }
                        
                        Spacer()
                        
                        // Individual undo button
                        if isHovering && canUndo {
                            Button {
                                showUndoConfirmation = true
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Undo this action")
                        }
                        
                        Text(item.formattedTime)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    // Original location
                    HStack(spacing: 4) {
                        Text(UICopy.History.originalLocation + ":")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(item.originalPath)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    
                    // Current location
                    if let currentPath = item.currentPath {
                        HStack(spacing: 4) {
                            Text(UICopy.History.currentLocation + ":")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            
                            if historyManager.fileExists(at: currentPath) {
                                Text(currentPath)
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                
                                if isHovering {
                                    Button {
                                        historyManager.revealInFinder(path: currentPath)
                                    } label: {
                                        Image(systemName: "folder")
                                            .font(.caption2)
                                    }
                                    .buttonStyle(.borderless)
                                    .help(UICopy.History.revealInFinder)
                                }
                            } else {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                    Text(UICopy.History.fileNotFound)
                                        .foregroundColor(.orange)
                                }
                                .font(.caption2)
                            }
                        }
                    }
                    
                    // Error message if failed
                    if item.outcome == .failed, let message = item.message {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                            Text(message)
                                .foregroundColor(.red)
                        }
                        .font(.caption2)
                    }
                }
                
                Spacer()
                
                // Outcome indicator
                outcomeIndicator
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background(isHovering ? Color.secondary.opacity(0.05) : Color.clear)
            .cornerRadius(6)
            .onHover { hovering in
                isHovering = hovering
            }
        }
        .alert("Undo Action?", isPresented: $showUndoConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Undo") {
                undoItem()
            }
        } message: {
            Text("This will restore '\(item.fileName)' to its original location.")
        }
        .sheet(isPresented: $showUndoResult) {
            if let result = undoResult {
                IndividualUndoResultView(result: result, onDismiss: {
                    showUndoResult = false
                    undoResult = nil
                    onUndo()
                })
            }
        }
    }
    
    private func undoItem() {
        undoResult = historyManager.undoItemInSession(item, in: session)
        showUndoResult = true
    }
    
    private var iconColor: Color {
        switch item.actionType {
        case .moved: return .blue
        case .copied: return .green
        case .deleted: return .orange
        case .renamed: return .purple
        case .skipped: return .gray
        }
    }
    
    @ViewBuilder
    private var outcomeIndicator: some View {
        switch item.outcome {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        case .skipped:
            Image(systemName: "minus.circle.fill")
                .foregroundColor(.gray)
        }
    }
}

// MARK: - Individual Undo Result View

struct IndividualUndoResultView: View {
    let result: HistoryManager.UndoItemResult
    let onDismiss: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: result.outcome == .restored ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(result.outcome == .restored ? .green : (result.outcome == .skipped ? .orange : .red))
                    .font(.title2)
                
                Text("Undo Result")
                    .font(.headline)
                
                Spacer()
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Content
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    Text(result.fileName)
                        .font(.title3)
                        .fontWeight(.medium)
                    
                    HStack(spacing: 8) {
                        Image(systemName: outcomeIcon)
                            .foregroundColor(outcomeColor)
                        Text(result.outcome == .restored ? "Restored" : (result.outcome == .skipped ? "Skipped" : "Failed"))
                            .fontWeight(.medium)
                            .foregroundColor(outcomeColor)
                    }
                }
                
                Text(result.message)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            Divider()
            
            // Footer
            HStack {
                Spacer()
                Button("OK") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 400, height: 300)
    }
    
    private var outcomeIcon: String {
        switch result.outcome {
        case .restored: return "checkmark.circle.fill"
        case .skipped: return "minus.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }
    
    private var outcomeColor: Color {
        switch result.outcome {
        case .restored: return .green
        case .skipped: return .orange
        case .failed: return .red
        }
    }
}

// MARK: - Global Search View

struct GlobalSearchView: View {
    @ObservedObject var appState: AppState
    @State private var searchText = ""
    @State private var selectedResult: SearchResultItem?
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignSystem.Spacing.xl) {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("Search")
                        .font(DesignSystem.Typography.title1)
                        .foregroundColor(.primary)
                    
                    Text("Search across files, rules, and history")
                        .font(DesignSystem.Typography.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding(DesignSystem.Spacing.xl)
            .background(DesignSystem.Colors.backgroundPrimary)
            
            Divider()
            
            VStack(spacing: DesignSystem.Spacing.md) {
                ModernSearchField(
                    text: $searchText,
                    placeholder: "Search files, rules, history..."
                )
                .onChange(of: searchText) { newValue in
                    appState.searchManager.search(query: newValue)
                }
                
                HStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(SearchableItemType.allCases, id: \.self) { type in
                        ModernFilterChip(
                            title: type.rawValue,
                            isSelected: appState.searchManager.selectedTypes.contains(type)
                        ) {
                            if appState.searchManager.selectedTypes.contains(type) {
                                appState.searchManager.selectedTypes.remove(type)
                            } else {
                                appState.searchManager.selectedTypes.insert(type)
                            }
                            if !searchText.isEmpty {
                                appState.searchManager.search(query: searchText)
                            }
                        }
                    }
                    
                    Spacer()
                }
            }
            .padding(DesignSystem.Spacing.xl)
            
            Divider()
            
            if appState.searchManager.searchResults.isEmpty {
                if searchText.isEmpty {
                    ModernEmptyState(
                        icon: "magnifyingglass",
                        title: "Start Searching",
                        description: "Type above to search across files, rules, and history."
                    )
                } else {
                    ModernEmptyState(
                        icon: "magnifyingglass.circle",
                        title: "No Results Found",
                        description: "Try adjusting your search terms or filters."
                    )
                }
            } else {
                SearchResultsList(
                    results: appState.searchManager.searchResults,
                    selectedResult: $selectedResult,
                    onResultSelected: { item in
                        handleResultSelection(item)
                    }
                )
            }
        }
        .background(DesignSystem.Colors.backgroundTertiary)
        .onAppear {
            appState.searchManager.updateData(
                files: appState.scanResult?.files ?? [],
                rules: appState.rules,
                history: appState.historyManager.sessions
            )
        }
    }
    
    private func handleResultSelection(_ item: SearchResultItem) {
        switch item.type {
        case .file:
            appState.selectedTab = .organize
        case .rule:
            appState.selectedTab = .rules
        case .history:
            appState.selectedTab = .history
        }
    }
}



struct SearchResultsList: View {
    let results: [SearchResultItem]
    @Binding var selectedResult: SearchResultItem?
    let onResultSelected: (SearchResultItem) -> Void
    
    var body: some View {
        List(selection: $selectedResult) {
            // Group by type
            let groupedResults = Dictionary(grouping: results) { $0.type }
            
            ForEach(SearchableItemType.allCases, id: \.self) { type in
                if let items = groupedResults[type], !items.isEmpty {
                    Section(header: Text(type.rawValue).font(.headline)) {
                        ForEach(items) { item in
                            SearchResultRow(item: item)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedResult = item
                                    onResultSelected(item)
                                }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

struct SearchResultRow: View {
    let item: SearchResultItem
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Statistics Dashboard View

struct StatisticsDashboardView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignSystem.Spacing.xl) {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("Statistics")
                        .font(DesignSystem.Typography.title1)
                        .foregroundColor(.primary)
                    
                    Text("Track rule effectiveness and file patterns")
                        .font(DesignSystem.Typography.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding(DesignSystem.Spacing.xl)
            .background(DesignSystem.Colors.backgroundPrimary)
            
            Divider()
            
            ScrollView {
                VStack(spacing: DesignSystem.Spacing.xl) {
                    StatisticsSummaryCards(appState: appState)
                    
                    Divider()
                    
                    if let scanResult = appState.scanResult {
                        FileTypesChart(files: scanResult.files)
                    }
                    
                    Divider()
                    
                    RulePerformanceSection(rules: appState.rules, history: appState.historyManager.sessions)
                    
                    Divider()
                    
                    RecentActivitySection(history: appState.historyManager.sessions)
                }
                .padding(DesignSystem.Spacing.xl)
            }
        }
        .background(DesignSystem.Colors.backgroundTertiary)
    }
}

struct StatisticsSummaryCards: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
            StatCard(
                title: "Total Files",
                value: "\(appState.scanResult?.files.count ?? 0)",
                icon: "doc",
                color: .blue
            )
            
            StatCard(
                title: "Active Rules",
                value: "\(appState.rules.filter(\.isEnabled).count)",
                icon: "list.bullet.rectangle",
                color: .green
            )
            
            StatCard(
                title: "Operations",
                value: "\(appState.historyManager.sessions.reduce(0) { $0 + $1.items.count })",
                icon: "clock.arrow.circlepath",
                color: .orange
            )
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(color)
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.title)
                    .fontWeight(.bold)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
    }
}

struct FileTypesChart: View {
    let files: [FileDescriptor]
    
    private var extensionCounts: [(String, Int)] {
        let counts = Dictionary(grouping: files) { $0.fileExtension }
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
        return Array(counts.prefix(10))
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("File Types")
                .font(.headline)
            
            if extensionCounts.isEmpty {
                Text("No files scanned yet")
                    .foregroundColor(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(extensionCounts, id: \.0) { ext, count in
                        HStack {
                            Text(ext.isEmpty ? "(no extension)" : ".\(ext)")
                                .font(.caption)
                                .frame(width: 80, alignment: .leading)
                            
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.secondary.opacity(0.1))
                                    
                                    if let maxCount = extensionCounts.first?.1 {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color.accentColor)
                                            .frame(width: geometry.size.width * CGFloat(count) / CGFloat(maxCount))
                                    }
                                }
                            }
                            .frame(height: 20)
                            
                            Text("\(count)")
                                .font(.caption)
                                .fontWeight(.medium)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }
}

struct RulePerformanceSection: View {
    let rules: [Rule]
    let history: [HistorySession]
    
    private var ruleStats: [(Rule, Int)] {
        // Count how many times each rule has been applied
        let stats: [UUID: Int] = [:]
        
        for session in history {
            for item in session.items where item.outcome == .success {
                // This is simplified - in production, you'd track which rule caused each action
                // For now, we'll show rule enablement status
            }
        }
        
        return rules.map { ($0, stats[$0.id] ?? 0) }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rule Performance")
                .font(.headline)
            
            if rules.isEmpty {
                Text("No rules configured")
                    .foregroundColor(.secondary)
            } else {
                VStack(spacing: 12) {
                    ForEach(rules.prefix(5)) { rule in
                        HStack {
                            Circle()
                                .fill(rule.isEnabled ? Color.green : Color.gray)
                                .frame(width: 8, height: 8)
                            
                            VStack(alignment: .leading) {
                                Text(rule.name)
                                    .fontWeight(.medium)
                                Text(rule.group ?? "Ungrouped")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            if rule.isEnabled {
                                Text("Active")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            } else {
                                Text("Disabled")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct RecentActivitySection: View {
    let history: [HistorySession]
    
    private var recentItems: [HistoryItem] {
        history.flatMap { $0.items }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(5)
            .map { $0 }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recent Activity")
                .font(.headline)
            
            if recentItems.isEmpty {
                Text("No recent activity")
                    .foregroundColor(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(recentItems) { item in
                        HStack {
                            Image(systemName: item.actionType.icon)
                                .foregroundColor(item.outcome == .success ? .green : .red)
                            
                            VStack(alignment: .leading) {
                                Text(item.fileName)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                Text(item.formattedTime)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Text(item.actionType.rawValue)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(4)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Template Browser View

struct TemplateBrowserView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedCategory: TemplateCategory?
    
    private var filteredTemplates: [RuleTemplate] {
        if let category = selectedCategory {
            return RuleTemplateLibrary.templates(for: category)
        }
        return RuleTemplateLibrary.allTemplates
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Rule Templates")
                        .font(.headline)
                    
                    Text("Choose a template to quickly create a rule")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.escape)
            }
            .padding()
            
            Divider()
            
            // Category filter
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ModernFilterChip(
                        title: "All",
                        isSelected: selectedCategory == nil
                    ) {
                        selectedCategory = nil
                    }
                    
                    ForEach(TemplateCategory.allCases, id: \.self) { category in
                        ModernFilterChip(
                            title: category.rawValue,
                            isSelected: selectedCategory == category
                        ) {
                            selectedCategory = category
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 8)
            
            Divider()
            
            // Templates grid
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280))], spacing: 16) {
                    ForEach(filteredTemplates) { template in
                        TemplateCard(template: template) {
                            // Add template as rule
                            appState.rules.append(template.rule)
                            dismiss()
                        }
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}

struct TemplateCard: View {
    let template: RuleTemplate
    let onApply: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: template.icon)
                    .font(.title2)
                    .foregroundColor(.accentColor)
                
                Spacer()
                
                Text(template.category.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(4)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(template.name)
                    .font(.headline)
                
                Text(template.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            
            Divider()
            
            HStack {
                // Show condition preview
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                    Text("\(template.rule.conditions.count) conditions")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button {
                    onApply()
                } label: {
                    Text("Use Template")
                        .fontWeight(.medium)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
    }
}
