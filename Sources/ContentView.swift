import SwiftUI
import UniformTypeIdentifiers

// MARK: - App State

@MainActor
class AppState: ObservableObject {
    @Published var rules: [Rule] = []
    @Published var selectedFolderURL: URL?
    @Published var scanResult: ScanResult?
    @Published var actionPlan: ActionPlan?
    @Published var executionLog: ExecutionLog?
    @Published var stalenessState: ScanStalenessState?
    
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
    
    let scanner = FileScanner()
    let planner = Planner()
    let executor: ExecutionEngine
    let undoEngine = UndoEngine()
    let scanBridge = ScanBridge()
    let historyManager = HistoryManager()
    let searchManager = SearchManager()
    
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
        
        // Load default rules
        loadDefaultRules()
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
            )
        ]
    }
}

enum SidebarTab: String, CaseIterable {
    case organize = "Organize"
    case rules = "Rules"
    case history = "History"
    case search = "Search"
    case statistics = "Statistics"
    
    var title: String {
        switch self {
        case .organize: return UICopy.Sidebar.organize
        case .rules: return UICopy.Sidebar.rules
        case .history: return UICopy.Sidebar.history
        case .search: return "Search"
        case .statistics: return "Statistics"
        }
    }
    
    var icon: String {
        switch self {
        case .organize: return "folder.badge.gearshape"
        case .rules: return "list.bullet.rectangle"
        case .history: return "clock.arrow.circlepath"
        case .search: return "magnifyingglass"
        case .statistics: return "chart.bar"
        }
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
        .listStyle(.sidebar)
        .frame(minWidth: 180)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                Divider()
                
                // Folder selector
                if let url = appState.selectedFolderURL {
                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundColor(.accentColor)
                        Text(url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.caption)
                    .padding(.horizontal, 12)
                }
                
                FolderSelectorButton(appState: appState)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
}

struct FolderSelectorButton: View {
    @ObservedObject var appState: AppState
    @State private var showFileImporter = false
    
    var body: some View {
        Button {
            showFileImporter = true
        } label: {
            Label(appState.selectedFolderURL == nil ? UICopy.Sidebar.selectFolder : UICopy.Sidebar.changeFolder,
                  systemImage: "folder.badge.plus")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                appState.selectedFolderURL = url
                appState.scanBridge.registerRoot(url)
                appState.stalenessState = ScanStalenessState(rootURL: url)
                appState.scanResult = nil
                appState.actionPlan = nil
                appState.executionLog = nil
            }
        }
    }
}

// MARK: - Organize View (Main)

struct OrganizeView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            OrganizeHeaderView(appState: appState)
            
            Divider()
            
            // Content
            if appState.selectedFolderURL == nil {
                EmptyFolderStateView()
            } else if appState.isScanning {
                ScanningStateView(appState: appState)
            } else if appState.isExecuting {
                ExecutingStateView()
            } else if let log = appState.executionLog {
                ExecutionResultsView(log: log, appState: appState)
            } else if let plan = appState.actionPlan {
                PlanPreviewView(plan: plan, appState: appState)
            } else if let result = appState.scanResult {
                ScanResultsView(result: result, appState: appState)
            } else {
                ReadyToScanView(appState: appState)
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }
}

struct OrganizeHeaderView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(UICopy.Header.organizeTitle)
                    .font(.title2)
                    .fontWeight(.semibold)
                
                stalenessLabel
            }
            
            Spacer()
            
            // Quick stats
            if let result = appState.scanResult {
                HStack(spacing: 16) {
                    StatBadge(value: "\(result.files.count)", label: "files")
                    StatBadge(value: "\(appState.rules.filter(\.isEnabled).count)", label: "active rules")
                }
            }
        }
        .padding(20)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    @ViewBuilder
    private var stalenessLabel: some View {
        if let state = appState.stalenessState {
            switch state.stalenessLevel {
            case .fresh:
                Label(UICopy.Header.scanUpToDate, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            case .possiblyStale:
                Label(UICopy.Header.scanMayBeStale, systemImage: "clock.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            case .stale:
                Label(UICopy.Header.scanRecommended, systemImage: "arrow.clockwise.circle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        } else {
            Text(UICopy.Header.noScanYet)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct StatBadge: View {
    let value: String
    let label: String
    
    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - State Views

struct EmptyFolderStateView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 64))
                .foregroundColor(.secondary.opacity(0.5))
            
            Text(UICopy.EmptyState.noFolderTitle)
                .font(.title3)
                .fontWeight(.medium)
            
            Text(UICopy.EmptyState.noFolderBody)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            
            Text(UICopy.EmptyState.nothingWillHappen)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ReadyToScanView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 64))
                .foregroundColor(.accentColor.opacity(0.7))
            
            VStack(spacing: 8) {
                Text(UICopy.EmptyState.readyToScanTitle)
                    .font(.title3)
                    .fontWeight(.medium)
                
                Text(UICopy.EmptyState.readyToScanBody)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            
            Button {
                startScan()
            } label: {
                Label(UICopy.EmptyState.startScanButton, systemImage: "magnifyingglass")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            
            Text(UICopy.EmptyState.ruleBasisHint(count: appState.rules.filter(\.isEnabled).count))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func startScan() {
        guard let url = appState.selectedFolderURL else { return }
        
        appState.isScanning = true
        appState.scanResult = nil
        appState.actionPlan = nil
        appState.executionLog = nil
        appState.scanProgress = nil
        
        Task {
            let result = await appState.scanner.scan(folderURL: url) { progress in
                Task { @MainActor in
                    appState.scanProgress = progress
                }
            }
            
            await MainActor.run {
                appState.scanResult = result
                appState.isScanning = false
                appState.scanProgress = nil
                appState.scanBridge.markScanCompleted(for: url)
                appState.stalenessState = appState.scanBridge.staleness(for: url)
                
                // Update search manager with new files
                appState.searchManager.updateData(files: result.files, rules: appState.rules, history: appState.historyManager.sessions)
                
                // Check for duplicates if scan wasn't cancelled
                if !result.wasCancelled {
                    Task {
                        await detectDuplicates(from: result.files)
                    }
                }
            }
        }
    }
    
    private func detectDuplicates(from files: [FileDescriptor]) async {
        // Group files by size
        let sizeGroups = Dictionary(grouping: files) { $0.fileSize }
        
        var duplicates: [[FileDescriptor]] = []
        for (_, group) in sizeGroups where group.count > 1 {
            // Simple duplicate detection by size
            // For production, would add hash checking
            duplicates.append(group)
        }
        
        await MainActor.run {
            appState.duplicateGroups = duplicates.filter { $0.count > 1 }
        }
    }
}

struct ScanningStateView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            
            Text(UICopy.Progress.scanningTitle)
                .font(.headline)
            
            // Progress indicator
            if let progress = appState.scanProgress {
                Text("\(progress.filesFound) files found...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                if let currentPath = progress.currentPath {
                    Text(currentPath)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 400)
                }
            }
            
            Text(UICopy.Progress.scanningBody)
                .font(.caption)
                .foregroundColor(.secondary)
            
            // Cancel button
            Button(role: .cancel) {
                appState.cancelScan()
            } label: {
                Label("Cancel Scan", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ExecutingStateView: View {
    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            
            Text(UICopy.Progress.executingTitle)
                .font(.headline)
            
            Text(UICopy.Progress.executingBody)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Scan Results View

struct ScanResultsView: View {
    let result: ScanResult
    @ObservedObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 0) {
            // Action bar
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(UICopy.Header.filesAnalyzed(result.files.count))
                        .font(.headline)
                    
                    if let time = appState.stalenessState?.lastScanTime {
                        Text(UICopy.Header.lastScanned(timeAgo(time)))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                Button(UICopy.Plan.createPlanButton) {
                    createPlan()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // File list
            List {
                ForEach(result.files.prefix(100)) { file in
                    FileRowView(file: file)
                }
                
                if result.files.count > 100 {
                    Text(UICopy.Common.andMore(result.files.count - 100))
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .listStyle(.inset)
        }
    }
    
    private func createPlan() {
        let enabledRules = appState.rules.filter(\.isEnabled)
        let plan = appState.planner.plan(files: result.files, rules: enabledRules)
        appState.actionPlan = plan
    }
    
    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
    }
}

struct FileRowView: View {
    let file: FileDescriptor
    
    var body: some View {
        HStack(spacing: 12) {
            // Use FileThumbnailView for actual thumbnails and QuickLook preview
            FileThumbnailView(file: file, size: 40, showPreviewOnTap: true)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(file.fileName)
                    .lineLimit(1)
                
                Text(file.fileURL.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            
            Spacer()
            
            if let size = file.fileSize, !file.isDirectory {
                Text(formatBytes(size))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Plan Preview View

struct PlanPreviewView: View {
    let plan: ActionPlan
    @ObservedObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with reassurance
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(UICopy.Plan.title)
                            .font(.headline)
                        
                        Text(UICopy.Plan.reassurance)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    HStack(spacing: 12) {
                        Button(UICopy.Plan.cancelButton) {
                            appState.actionPlan = nil
                        }
                        .buttonStyle(.bordered)
                        
                        Button {
                            executePlan()
                        } label: {
                            Label(UICopy.Plan.approveButton, systemImage: "checkmark")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                
                // Summary badges
                PlanSummaryBadges(plan: plan)
            }
            .padding(16)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Action list
            List {
                ForEach(plan.actions) { action in
                    PlannedActionRowView(action: action)
                }
            }
            .listStyle(.inset)
            
            // Footer hint
            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                Text(UICopy.Plan.confidenceHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(12)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
    
    private func executePlan() {
        appState.isExecuting = true
        
        let executor = appState.executor
        let folderPath = appState.selectedFolderURL?.path ?? "Unknown"
        
        DispatchQueue.global(qos: .userInitiated).async {
            let log = executor.execute(plan: plan)
            
            DispatchQueue.main.async {
                appState.executionLog = log
                appState.actionPlan = nil
                appState.isExecuting = false
                
                // Save to history
                appState.historyManager.recordSession(from: log, folderPath: folderPath)
            }
        }
    }
}

struct PlanSummaryBadges: View {
    let plan: ActionPlan
    
    var body: some View {
        let moveCount = plan.actions.filter { if case .move = $0.actionType { return true }; return false }.count
        let deleteCount = plan.actions.filter { if case .delete = $0.actionType { return true }; return false }.count
        let skipCount = plan.actions.filter { if case .skip = $0.actionType { return true }; return false }.count
        
        HStack(spacing: 8) {
            if moveCount > 0 {
                Badge(text: UICopy.Plan.summaryMoved(moveCount), color: .blue)
            }
            if deleteCount > 0 {
                Badge(text: UICopy.Plan.summaryTrash(deleteCount), color: .orange)
            }
            if skipCount > 0 {
                Badge(text: UICopy.Plan.summarySkipped(skipCount), color: .secondary)
            }
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color
    
    var body: some View {
        Text(text)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(6)
    }
}

struct PlannedActionRowView: View {
    let action: PlannedAction
    
    var body: some View {
        HStack(spacing: 12) {
            // File thumbnail with preview
            FileThumbnailView(file: action.targetFile, size: 36, showPreviewOnTap: true)
            
            // Status icon
            actionIcon
                .frame(width: 28)
            
            VStack(alignment: .leading, spacing: 4) {
                // File → Destination
                HStack(spacing: 6) {
                    Text(action.targetFile.fileName)
                        .fontWeight(.medium)
                    
                    destinationText
                }
                
                // Reason
                Text(UICopy.Plan.reason(action.reason))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(.vertical, 6)
    }
    
    @ViewBuilder
    private var actionIcon: some View {
        switch action.actionType {
        case .move:
            Image(systemName: "arrow.right.circle.fill")
                .foregroundColor(.blue)
        case .delete:
            Image(systemName: "trash.circle.fill")
                .foregroundColor(.orange)
        case .skip:
            Image(systemName: "minus.circle.fill")
                .foregroundColor(.secondary)
        case .copy:
            Image(systemName: "doc.on.doc.fill")
                .foregroundColor(.green)
        case .rename:
            Image(systemName: "pencil.circle.fill")
                .foregroundColor(.purple)
        }
    }
    
    @ViewBuilder
    private var destinationText: some View {
        switch action.actionType {
        case .move(let dest):
            Text("→ \(dest.lastPathComponent)")
                .foregroundColor(.secondary)
        case .delete:
            Text("→ Trash")
                .foregroundColor(.orange)
        case .skip:
            Text("(no action)")
                .foregroundColor(.secondary)
                .italic()
        case .copy(let dest):
            Text("→ copy to \(dest.lastPathComponent)")
                .foregroundColor(.secondary)
        case .rename(let newName):
            Text("→ \(newName)")
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Execution Results View

struct ExecutionResultsView: View {
    let log: ExecutionLog
    @ObservedObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(UICopy.Execution.title)
                            .font(.headline)
                        
                        summaryText
                    }
                    
                    Spacer()
                    
                    HStack(spacing: 12) {
                        Button(UICopy.Execution.undoButton) {
                            performUndo()
                        }
                        .buttonStyle(.bordered)
                        
                        Button(UICopy.Execution.doneButton) {
                            appState.executionLog = nil
                            appState.scanResult = nil
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(16)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Results list
            List {
                ForEach(log.entries, id: \.actionId) { entry in
                    ExecutionEntryRowView(entry: entry)
                }
            }
            .listStyle(.inset)
        }
    }
    
    private var summaryText: some View {
        let successCount = log.entries.filter { $0.outcome == .success }.count
        let failCount = log.entries.filter { $0.outcome == .failed }.count
        
        if failCount > 0 {
            return Text(UICopy.Execution.partialFailure)
                .font(.caption)
                .foregroundColor(.orange)
        } else {
            return Text(UICopy.Execution.successSummary(successCount))
                .font(.caption)
                .foregroundColor(.green)
        }
    }
    
    private func performUndo() {
        appState.isExecuting = true
        
        let undoEngine = appState.undoEngine
        DispatchQueue.global(qos: .userInitiated).async {
            let _ = undoEngine.undo(log: log)
            
            DispatchQueue.main.async {
                appState.executionLog = nil
                appState.scanResult = nil
                appState.isExecuting = false
            }
        }
    }
}

struct ExecutionEntryRowView: View {
    let entry: ExecutionLog.Entry
    
    var body: some View {
        HStack(spacing: 12) {
            outcomeIcon
                .frame(width: 28)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.sourceURL.lastPathComponent)
                    .fontWeight(.medium)
                
                outcomeText
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
    
    @ViewBuilder
    private var outcomeIcon: some View {
        switch entry.outcome {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .skipped:
            Image(systemName: "arrow.uturn.right.circle.fill")
                .foregroundColor(.orange)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        }
    }
    
    @ViewBuilder
    private var outcomeText: some View {
        switch entry.outcome {
        case .success:
            if let dest = entry.destinationURL {
                Text(UICopy.Execution.movedTo(dest.lastPathComponent))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text(UICopy.Execution.completed)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .skipped:
            Text(UICopy.Execution.skipped(entry.message ?? UICopy.Common.unknownReason))
                .font(.caption)
                .foregroundColor(.orange)
        case .failed:
            Text(UICopy.Execution.failed(entry.message ?? UICopy.Common.unknownReason))
                .font(.caption)
                .foregroundColor(.red)
        }
    }
}

// MARK: - Rules View

struct RulesView: View {
    @ObservedObject var appState: AppState
    @State private var showingAddRule = false
    @State private var editingRule: Rule?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with filters
            RulesHeaderView(appState: appState, showingAddRule: $showingAddRule)
            
            Divider()
            
            // Rules list
            if appState.filteredRules.isEmpty {
                if appState.rules.isEmpty {
                    EmptyRulesView()
                } else {
                    NoMatchingRulesView()
                }
            } else {
                List {
                    // Group rules by their group
                    let groupedRules = Dictionary(grouping: appState.filteredRules) { $0.group ?? "Ungrouped" }
                    let sortedGroups = groupedRules.keys.sorted()
                    
                    ForEach(sortedGroups, id: \.self) { group in
                        Section(header: Text(group)
                            .font(.headline)
                            .foregroundColor(.secondary)) {
                            ForEach(groupedRules[group] ?? []) { rule in
                                RuleRowView(rule: rule, appState: appState, onEdit: {
                                    editingRule = rule
                                })
                            }
                            .onDelete { indexSet in
                                // Need to find actual indices in main rules array
                                let rulesInGroup = groupedRules[group] ?? []
                                let rulesToDelete = indexSet.map { rulesInGroup[$0] }
                                appState.rules.removeAll { rule in
                                    rulesToDelete.contains { $0.id == rule.id }
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .sheet(isPresented: $showingAddRule) {
            RuleEditorView(appState: appState, existingRule: nil)
        }
        .sheet(item: $editingRule) { rule in
            RuleEditorView(appState: appState, existingRule: rule)
        }
    }
}

struct RulesHeaderView: View {
    @ObservedObject var appState: AppState
    @Binding var showingAddRule: Bool
    @State private var showingTemplates = false
    
    var body: some View {
        VStack(spacing: 12) {
            // Main header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(UICopy.Rules.title)
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text(UICopy.Rules.subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                HStack(spacing: 8) {
                    Button {
                        showingTemplates = true
                    } label: {
                        Label("Templates", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    
                    Button {
                        showingAddRule = true
                    } label: {
                        Label(UICopy.Rules.addButton, systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .sheet(isPresented: $showingTemplates) {
                TemplateBrowserView(appState: appState)
            }
            
            // Filters
            HStack(spacing: 12) {
                // Search field
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search rules...", text: $appState.ruleSearchText)
                        .textFieldStyle(.plain)
                    if !appState.ruleSearchText.isEmpty {
                        Button {
                            appState.ruleSearchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
                
                // Group filter
                if !appState.ruleGroups.isEmpty {
                    Picker("Group", selection: $appState.selectedRuleGroup) {
                        Text("All Groups")
                            .tag(nil as String?)
                        ForEach(appState.ruleGroups, id: \.self) { group in
                            Text(group)
                                .tag(group as String?)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }
                
                Spacer()
                
                // Rule count
                Text("\(appState.filteredRules.count) of \(appState.rules.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct NoMatchingRulesView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
            
            Text("No matching rules")
                .font(.title3)
                .fontWeight(.medium)
            
            Text("Try adjusting your search or filter criteria.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyRulesView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
            
            Text(UICopy.Rules.emptyTitle)
                .font(.title3)
                .fontWeight(.medium)
            
            Text(UICopy.Rules.emptyBody)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RuleRowView: View {
    let rule: Rule
    @ObservedObject var appState: AppState
    let onEdit: () -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            // Enable toggle
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { newValue in
                    if let index = appState.rules.firstIndex(where: { $0.id == rule.id }) {
                        let updated = Rule(
                            id: rule.id,
                            name: rule.name,
                            description: rule.description,
                            conditions: rule.conditions,
                            outcome: rule.outcome,
                            isEnabled: newValue,
                            group: rule.group,
                            tags: rule.tags
                        )
                        appState.rules[index] = updated
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            
            // Rule info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(rule.name)
                        .fontWeight(.medium)
                    
                    if !rule.isEnabled {
                        Text(UICopy.Rules.disabled)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.2))
                            .cornerRadius(4)
                    }
                    
                    // Tags
                    if !rule.tags.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(rule.tags.prefix(3), id: \.self) { tag in
                                Text(tag)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.1))
                                    .foregroundColor(.accentColor)
                                    .cornerRadius(4)
                            }
                            if rule.tags.count > 3 {
                                Text("+\(rule.tags.count - 3)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                
                Text(rule.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                // Condition summary
                HStack(spacing: 8) {
                    ForEach(Array(rule.conditions.enumerated()), id: \.offset) { _, condition in
                        ConditionBadge(condition: condition)
                    }
                    
                    Text("→")
                        .foregroundColor(.secondary)
                    
                    OutcomeBadge(outcome: rule.outcome)
                }
                .font(.caption2)
            }
            
            Spacer()
            
            // Edit button
            Button(UICopy.Rules.editButton) {
                onEdit()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 8)
        .opacity(rule.isEnabled ? 1 : 0.6)
    }
}

struct ConditionBadge: View {
    let condition: RuleCondition
    
    var body: some View {
        Text(conditionText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.blue.opacity(0.1))
            .foregroundColor(.blue)
            .cornerRadius(4)
    }
    
    private var conditionText: String {
        switch condition {
        case .fileExtension(let ext):
            return UICopy.Common.conditionExt(ext)
        case .fileName(let contains):
            return UICopy.Common.conditionContains(contains)
        case .fileSize(let bytes):
            return UICopy.Common.conditionSize(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        case .createdBefore(let date):
            return "created " + UICopy.Common.conditionDate(date.formatted(date: .abbreviated, time: .omitted))
        case .modifiedBefore(let date):
            return "modified " + UICopy.Common.conditionDate(date.formatted(date: .abbreviated, time: .omitted))
        case .isDirectory:
            return UICopy.Common.conditionFolder
        }
    }
}

struct OutcomeBadge: View {
    let outcome: RuleOutcome
    
    var body: some View {
        Text(outcomeText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(outcomeColor.opacity(0.1))
            .foregroundColor(outcomeColor)
            .cornerRadius(4)
    }
    
    private var outcomeText: String {
        switch outcome {
        case .move(let url):
            return UICopy.Execution.movedTo(url.lastPathComponent)
        case .copy(let url):
            return "Copy to \(url.lastPathComponent)" // TODO: Add copy to UICopy if needed, using raw string for now slightly distinct from movedTo
        case .delete:
            return UICopy.Rules.actionDelete
        case .rename(let prefix, let suffix):
            return UICopy.Common.outcomeRename(prefix, suffix)
        case .skip(let reason):
            return UICopy.Execution.skipped(reason)
        }
    }
    
    private var outcomeColor: Color {
        switch outcome {
        case .move: return .green
        case .copy: return .blue
        case .delete: return .orange
        case .rename: return .purple
        case .skip: return .secondary
        }
    }
}

// MARK: - Rule Editor

struct RuleEditorView: View {
    @ObservedObject var appState: AppState
    let existingRule: Rule?
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var name: String = ""
    @State private var description: String = ""
    @State private var conditionType: ConditionType = .fileExtension
    @State private var conditionValue: String = ""
    @State private var outcomeType: OutcomeType = .move
    @State private var destinationPath: String = ""
    @State private var showSecurityError = false
    @State private var group: String = ""
    @State private var tags: String = ""
    
    enum ConditionType: String, CaseIterable {
        case fileExtension
        case fileName
        case fileSize
        
        var rawValue: String {
            switch self {
            case .fileExtension: return UICopy.Rules.conditionExtension
            case .fileName: return UICopy.Rules.conditionName
            case .fileSize: return UICopy.Rules.conditionSize
            }
        }
    }
    
    enum OutcomeType: String, CaseIterable {
        case move
        case delete
        
        var rawValue: String {
            switch self {
            case .move: return UICopy.Rules.actionMove
            case .delete: return UICopy.Rules.actionDelete
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(existingRule == nil ? UICopy.Rules.editorAddTitle : UICopy.Rules.editorEditTitle)
                    .font(.headline)
                
                Spacer()
                
                Button(UICopy.Rules.cancelButton) {
                    dismiss()
                }
                .keyboardShortcut(.escape)
            }
            .padding()
            
            Divider()
            
            // Form
            // Custom Form Layout
            ScrollView {
                VStack(spacing: 24) {
                    
                    // Group 1: Basics
                    GroupBox(label: Text(UICopy.Rules.sectionDetails).font(.headline)) {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Name", text: $name, prompt: Text(UICopy.Rules.namePlaceholder))
                            TextField("Description", text: $description, prompt: Text(UICopy.Rules.descPlaceholder))
                            
                            // Group picker (existing groups + custom)
                            HStack {
                                Text("Group:")
                                    .foregroundColor(.secondary)
                                TextField("Group name", text: $group, prompt: Text("Optional"))
                                if !appState.ruleGroups.isEmpty {
                                    Picker("", selection: $group) {
                                        Text("Select...")
                                            .tag("")
                                        ForEach(appState.ruleGroups, id: \.self) { existingGroup in
                                            Text(existingGroup)
                                                .tag(existingGroup)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(width: 120)
                                }
                            }
                            
                            // Tags input
                            HStack {
                                Text("Tags:")
                                    .foregroundColor(.secondary)
                                TextField("Comma separated tags", text: $tags, prompt: Text("e.g., important, archive, work"))
                            }
                        }
                        .padding(8)
                    }
                    
                    // Group 2: Conditions
                    GroupBox(label: Text(UICopy.Rules.sectionConditions).font(.headline)) {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Condition", selection: $conditionType) {
                                ForEach(ConditionType.allCases, id: \.self) { type in
                                    Text(type.rawValue).tag(type)
                                }
                            }
                            .labelsHidden()
                            
                            switch conditionType {
                            case .fileExtension:
                                TextField("Extension", text: $conditionValue, prompt: Text("pdf"))
                            case .fileName:
                                TextField("Contains", text: $conditionValue, prompt: Text("Screenshot"))
                            case .fileSize:
                                TextField("Size in MB", text: $conditionValue, prompt: Text("100"))
                            }
                        }
                        .padding(8)
                    }
                    
                    // Group 3: Outcomes
                    GroupBox(label: Text(UICopy.Rules.sectionOutcomes).font(.headline)) {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Action", selection: $outcomeType) {
                                ForEach(OutcomeType.allCases, id: \.self) { type in
                                    Text(type.rawValue).tag(type)
                                }
                            }
                            .labelsHidden()
                            
                            if outcomeType == .move {
                                TextField("Destination folder path", text: $destinationPath, prompt: Text("~/Documents/Archive"))
                            }
                        }
                        .padding(8)
                    }
                }
                .padding()
            }
            
            Divider()
            
            // Footer
            HStack {
                Spacer()
                
                Button(UICopy.Rules.saveButton) {
                    saveRule()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty)
            }
            .padding()
        }
        .frame(width: 500, height: 450)
        .alert("Security Error", isPresented: $showSecurityError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The selected destination path is not allowed. Please choose a path within your home directory or Documents folder.")
        }
        .onAppear {
            if let rule = existingRule {
                name = rule.name
                description = rule.description
                group = rule.group ?? ""
                tags = rule.tags.joined(separator: ", ")
                // Parse existing conditions/outcomes for editing
            }
        }
    }
    
    private func saveRule() {
        let condition: RuleCondition
        switch conditionType {
        case .fileExtension:
            condition = .fileExtension(is: conditionValue)
        case .fileName:
            condition = .fileName(contains: conditionValue)
        case .fileSize:
            let mb = Int64(conditionValue) ?? 100
            condition = .fileSize(largerThan: mb * 1_000_000)
        }
        
        let outcome: RuleOutcome
        switch outcomeType {
        case .move:
            let path = destinationPath.isEmpty ? NSHomeDirectory() + "/Documents/Organized" : 
                       (destinationPath.hasPrefix("~") ? NSHomeDirectory() + destinationPath.dropFirst() : destinationPath)
            // Security: Validate path is within allowed directories
            guard isPathAllowed(path) else {
                showSecurityError = true
                return
            }
            outcome = .move(to: URL(fileURLWithPath: path))
        case .delete:
            outcome = .delete
        }
        
        let rule = Rule(
            id: existingRule?.id ?? UUID(),
            name: name,
            description: description,
            conditions: [condition],
            outcome: outcome,
            group: group.isEmpty ? nil : group,
            tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        )
        
        if let existing = existingRule,
           let index = appState.rules.firstIndex(where: { $0.id == existing.id }) {
            appState.rules[index] = rule
        } else {
            appState.rules.append(rule)
        }
        
        dismiss()
    }
    
    /// Security validation: Ensure path is within allowed user directories
    private func isPathAllowed(_ path: String) -> Bool {
        let allowedPrefixes = [
            NSHomeDirectory(),
            "/Users/",
            "/tmp/",
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? ""
        ]
        
        let resolvedPath = (path as NSString).standardizingPath
        
        // Block system-critical paths
        let blockedPrefixes = [
            "/System",
            "/usr/bin",
            "/usr/sbin",
            "/bin",
            "/sbin",
            "/etc",
            "/var",
            "/private",
            "/dev",
            "/Applications",
            NSHomeDirectory() + "/Library"
        ]
        
        // Check if path is in blocked list
        for blocked in blockedPrefixes {
            if resolvedPath.hasPrefix(blocked) {
                return false
            }
        }
        
        // Check if path is within allowed user directories
        return allowedPrefixes.contains { resolvedPath.hasPrefix($0) }
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
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(UICopy.History.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text(UICopy.History.subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if !appState.historyManager.sessions.isEmpty {
                // Stats
                HStack(spacing: 16) {
                    StatBadge(
                        value: "\(appState.historyManager.sessions.count)",
                        label: "sessions"
                    )
                    StatBadge(
                        value: "\(totalItems)",
                        label: "operations"
                    )
                }
                
                Button(UICopy.History.clearAllButton) {
                    showClearConfirmation = true
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
            }
        }
        .padding(20)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private var totalItems: Int {
        appState.historyManager.sessions.reduce(0) { $0 + $1.items.count }
    }
}

struct HistoryEmptyStateView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 64))
                .foregroundColor(.secondary.opacity(0.5))
            
            Text(UICopy.History.emptyTitle)
                .font(.title3)
                .fontWeight(.medium)
            
            Text(UICopy.History.emptyBody)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Search")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("Search across files, rules, and history")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding(20)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Search Bar
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    
                    TextField("Search files, rules, history...", text: $searchText)
                        .textFieldStyle(.plain)
                        .onChange(of: searchText) { newValue in
                            appState.searchManager.search(query: newValue)
                        }
                    
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            appState.searchManager.clearSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
                
                // Filter chips
                HStack(spacing: 8) {
                    ForEach(SearchableItemType.allCases, id: \.self) { type in
                        FilterChip(
                            title: type.rawValue,
                            isSelected: appState.searchManager.selectedTypes.contains(type)
                        ) {
                            if appState.searchManager.selectedTypes.contains(type) {
                                appState.searchManager.selectedTypes.remove(type)
                            } else {
                                appState.searchManager.selectedTypes.insert(type)
                            }
                            // Re-run search with new filters
                            if !searchText.isEmpty {
                                appState.searchManager.search(query: searchText)
                            }
                        }
                    }
                    
                    Spacer()
                }
            }
            .padding()
            
            Divider()
            
            // Results
            if appState.searchManager.searchResults.isEmpty {
                if searchText.isEmpty {
                    SearchEmptyStateView()
                } else {
                    NoSearchResultsView()
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
        .background(Color(NSColor.textBackgroundColor))
        .onAppear {
            // Update search manager with current data
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

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.1))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }
}

struct SearchEmptyStateView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 64))
                .foregroundColor(.secondary.opacity(0.5))
            
            Text("Start Searching")
                .font(.title3)
                .fontWeight(.medium)
            
            Text("Type above to search across files, rules, and history.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NoSearchResultsView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 64))
                .foregroundColor(.secondary.opacity(0.5))
            
            Text("No Results Found")
                .font(.title3)
                .fontWeight(.medium)
            
            Text("Try adjusting your search terms or filters.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Statistics")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("Track rule effectiveness and file patterns")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding(20)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Stats Content
            ScrollView {
                VStack(spacing: 20) {
                    // Summary Cards
                    StatisticsSummaryCards(appState: appState)
                    
                    Divider()
                    
                    // File Types Breakdown
                    if let scanResult = appState.scanResult {
                        FileTypesChart(files: scanResult.files)
                    }
                    
                    Divider()
                    
                    // Rule Performance
                    RulePerformanceSection(rules: appState.rules, history: appState.historyManager.sessions)
                    
                    Divider()
                    
                    // Recent Activity
                    RecentActivitySection(history: appState.historyManager.sessions)
                }
                .padding()
            }
        }
        .background(Color(NSColor.textBackgroundColor))
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
        var stats: [UUID: Int] = [:]
        
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
                    FilterChip(
                        title: "All",
                        isSelected: selectedCategory == nil
                    ) {
                        selectedCategory = nil
                    }
                    
                    ForEach(TemplateCategory.allCases, id: \.self) { category in
                        FilterChip(
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
