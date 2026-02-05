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
    
    let scanner = FileScanner()
    let planner = Planner()
    let executor = ExecutionEngine()
    let undoEngine = UndoEngine()
    let scanBridge = ScanBridge()
    
    init() {
        // Load default rules
        loadDefaultRules()
    }
    
    private func loadDefaultRules() {
        rules = [
            Rule(
                name: "Archive PDFs",
                description: "Move PDF files to the Archive folder",
                conditions: [.fileExtension(is: "pdf")],
                outcome: .move(to: URL(fileURLWithPath: NSHomeDirectory() + "/Documents/Archive/PDFs"))
            ),
            Rule(
                name: "Organize Screenshots",
                description: "Move screenshots to Screenshots folder",
                conditions: [.fileName(contains: "Screenshot")],
                outcome: .move(to: URL(fileURLWithPath: NSHomeDirectory() + "/Pictures/Screenshots"))
            ),
            Rule(
                name: "Clean Large Downloads",
                description: "Move files larger than 100MB to a review folder",
                conditions: [.fileSize(largerThan: 100_000_000)],
                outcome: .move(to: URL(fileURLWithPath: NSHomeDirectory() + "/Documents/LargeFiles")),
                isEnabled: false
            )
        ]
    }
}

enum SidebarTab: String, CaseIterable {
    case organize = "Organize" // Raw value needs to remain string for CaseIterable/Serialization if needed, but UI uses localized
    case rules = "Rules"
    case history = "History"
    
    var title: String {
        switch self {
        case .organize: return UICopy.Sidebar.organize
        case .rules: return UICopy.Sidebar.rules
        case .history: return UICopy.Sidebar.history
        }
    }
    
    var icon: String {
        switch self {
        case .organize: return "folder.badge.gearshape"
        case .rules: return "list.bullet.rectangle"
        case .history: return "clock.arrow.circlepath"
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
                ScanningStateView()
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
        
        Task {
            let result = await appState.scanner.scan(folderURL: url)
            
            await MainActor.run {
                appState.scanResult = result
                appState.isScanning = false
                appState.scanBridge.markScanCompleted(for: url)
                appState.stalenessState = appState.scanBridge.staleness(for: url)
            }
        }
    }
}

struct ScanningStateView: View {
    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            
            Text(UICopy.Progress.scanningTitle)
                .font(.headline)
            
            Text(UICopy.Progress.scanningBody)
                .font(.caption)
                .foregroundColor(.secondary)
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
            Image(systemName: file.isDirectory ? "folder.fill" : fileIcon)
                .foregroundColor(file.isDirectory ? .blue : .secondary)
                .frame(width: 24)
            
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
    
    private var fileIcon: String {
        switch file.fileExtension.lowercased() {
        case "pdf": return "doc.fill"
        case "jpg", "jpeg", "png", "gif", "heic": return "photo.fill"
        case "mp4", "mov", "avi": return "film.fill"
        case "mp3", "wav", "m4a": return "music.note"
        case "zip", "rar", "7z": return "archivebox.fill"
        default: return "doc.fill"
        }
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
        DispatchQueue.global(qos: .userInitiated).async {
            let log = executor.execute(plan: plan)
            
            DispatchQueue.main.async {
                appState.executionLog = log
                appState.actionPlan = nil
                appState.isExecuting = false
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
            // Header
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
                
                Button {
                    showingAddRule = true
                } label: {
                    Label(UICopy.Rules.addButton, systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(20)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Rules list
            if appState.rules.isEmpty {
                EmptyRulesView()
            } else {
                List {
                    ForEach(appState.rules) { rule in
                        RuleRowView(rule: rule, appState: appState, onEdit: {
                            editingRule = rule
                        })
                    }
                    .onDelete { indexSet in
                        appState.rules.remove(atOffsets: indexSet)
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
                            isEnabled: newValue
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
        .onAppear {
            if let rule = existingRule {
                name = rule.name
                description = rule.description
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
            outcome = .move(to: URL(fileURLWithPath: path))
        case .delete:
            outcome = .delete
        }
        
        let rule = Rule(
            id: existingRule?.id ?? UUID(),
            name: name,
            description: description,
            conditions: [condition],
            outcome: outcome
        )
        
        if let existing = existingRule,
           let index = appState.rules.firstIndex(where: { $0.id == existing.id }) {
            appState.rules[index] = rule
        } else {
            appState.rules.append(rule)
        }
        
        dismiss()
    }
}

// MARK: - History View

struct HistoryView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
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
            }
            .padding(20)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Empty state for now
            VStack(spacing: 16) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary.opacity(0.5))
                
                Text(UICopy.History.emptyTitle)
                    .font(.title3)
                    .fontWeight(.medium)
                
                Text(UICopy.History.emptyBody)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(NSColor.textBackgroundColor))
    }
}
