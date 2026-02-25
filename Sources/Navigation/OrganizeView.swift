import SwiftUI
import ClippyCore
import ClippyEngine
import CryptoKit

struct OrganizeView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 0) {
            quickActionsToolbar
            OrganizeHeaderView(appState: appState)
            Divider()
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
        MemoryStatusBar(appState: appState)
    }
        .sheet(isPresented: $appState.showDuplicates) {
            DuplicatesView(appState: appState)
        }
    }
    
    @ViewBuilder
    private var quickActionsToolbar: some View {
        HStack(spacing: 12) {
            Button {
                startScan()
            } label: {
                Label("Scan", systemImage: "magnifyingglass")
            }
            .disabled(appState.selectedFolderURL == nil || appState.isScanning || appState.isExecuting)
            
            Divider()
                .frame(height: 20)
            
            Button {
                createPlan()
            } label: {
                Label("Create Plan", systemImage: "list.bullet.rectangle")
            }
            .disabled(appState.scanResult == nil || appState.actionPlan != nil)
            
            Button {
                executePlan()
            } label: {
                Label("Execute", systemImage: "play.fill")
            }
            .disabled(appState.actionPlan == nil || appState.isExecuting)
            .buttonStyle(.borderedProminent)
            
            Button {
                performUndo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(appState.executionLog == nil)
            
            Spacer()
            
            if appState.duplicateGroups.count > 1 {
                Button {
                    appState.showDuplicates = true
                } label: {
                    Label("Duplicates (\(appState.duplicateGroups.count))", systemImage: "doc.on.doc.fill")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
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
                appState.searchManager.updateData(files: result.files, rules: appState.rules, history: appState.historyManager.sessions)
                if !result.wasCancelled {
                    Task { await detectDuplicates(from: result.files) }
                }
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
            appState.duplicateGroups = duplicates
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
        var hasher = SHA256()
        
        while let data = try? fileHandle.read(upToCount: bufferSize), !data.isEmpty {
            hasher.update(data: data)
        }
        
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    private func createPlan() {
        guard let result = appState.scanResult else { return }
        let enabledRules = appState.rules.filter(\.isEnabled)
        let plan = appState.planner.plan(files: result.files, rules: enabledRules)
        appState.actionPlan = plan
    }
    
    private func executePlan() {
        guard let plan = appState.actionPlan else { return }
        appState.isExecuting = true
        let executor = appState.executor
        let folderPath = appState.selectedFolderURL?.path ?? "Unknown"
        DispatchQueue.global(qos: .userInitiated).async {
            let log = executor.execute(plan: plan)
            DispatchQueue.main.async {
                appState.executionLog = log
                appState.actionPlan = nil
                appState.isExecuting = false
                appState.historyManager.recordSession(from: log, folderPath: folderPath)
            }
        }
    }
    
    private func performUndo() {
        guard let log = appState.executionLog else { return }
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

struct OrganizeHeaderView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        HStack(spacing: DesignSystem.Spacing.xl) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(UICopy.Header.organizeTitle)
                    .font(DesignSystem.Typography.title1)
                    .foregroundColor(.primary)
                stalenessLabel
            }
            Spacer()
            if let result = appState.scanResult {
                HStack(spacing: DesignSystem.Spacing.md) {
                    ModernQuickStat(
                        value: "\(result.files.count)",
                        label: "files",
                        icon: "doc.fill",
                        color: DesignSystem.Colors.accentBlue
                    )
                    ModernQuickStat(
                        value: "\(appState.rules.filter(\.isEnabled).count)",
                        label: "active rules",
                        icon: "list.bullet",
                        color: DesignSystem.Colors.accentTeal
                    )
                }
            }
        }
        .padding(DesignSystem.Spacing.xl)
        .background(DesignSystem.Colors.backgroundPrimary)
    }
    
    @ViewBuilder
    private var stalenessLabel: some View {
        if let state = appState.stalenessState {
            switch state.stalenessLevel {
            case .fresh:
                Label(UICopy.Header.scanUpToDate, systemImage: "checkmark.circle.fill")
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(.green)
            case .possiblyStale:
                Label(UICopy.Header.scanMayBeStale, systemImage: "clock.fill")
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(.orange)
            case .stale:
                Label(UICopy.Header.scanRecommended, systemImage: "arrow.clockwise.circle.fill")
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(.orange)
            }
        } else {
            Text(UICopy.Header.noScanYet)
                .font(DesignSystem.Typography.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct StatBadge: View {
    let value: String
    let label: String
    
    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }
}

struct EmptyFolderStateView: View {
    var body: some View {
        ModernEmptyState(
            icon: "folder.badge.questionmark",
            title: UICopy.EmptyState.noFolderTitle,
            description: UICopy.EmptyState.noFolderBody
        )
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
                appState.searchManager.updateData(files: result.files, rules: appState.rules, history: appState.historyManager.sessions)
                if !result.wasCancelled {
                    Task { await detectDuplicates(from: result.files) }
                }
            }
        }
    }
    
    private func detectDuplicates(from files: [FileDescriptor]) async {
        let sizeGroups = Dictionary(grouping: files) { $0.fileSize }
        var duplicates: [[FileDescriptor]] = []
        for (_, group) in sizeGroups where group.count > 1 {
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
            ProgressView().scaleEffect(1.5)
            Text(UICopy.Progress.scanningTitle).font(.headline)
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
            ProgressView().scaleEffect(1.5)
            Text(UICopy.Progress.executingTitle).font(.headline)
            Text(UICopy.Progress.executingBody)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ScanResultsView: View {
    let result: ScanResult
    @ObservedObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(UICopy.Header.filesAnalyzed(result.files.count)).font(.headline)
                    if let time = appState.stalenessState?.lastScanTime {
                        Text(UICopy.Header.lastScanned(timeAgo(time)))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Button(UICopy.Plan.createPlanButton) { createPlan() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
            .background(Color(NSColor.windowBackgroundColor))
            Divider()
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
            FileThumbnailView(file: file, size: 40, showPreviewOnTap: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.fileName).lineLimit(1)
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

struct PlanPreviewView: View {
    let plan: ActionPlan
    @ObservedObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        Text(UICopy.Plan.title)
                            .font(DesignSystem.Typography.title2)
                            .foregroundColor(.primary)
                        Text(UICopy.Plan.reassurance)
                            .font(DesignSystem.Typography.body)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    PlanSummaryBadges(plan: plan)
                }
                
                HStack(spacing: DesignSystem.Spacing.md) {
                    Button(UICopy.Plan.cancelButton) { appState.actionPlan = nil }
                        .buttonStyle(SecondaryButtonStyle())
                        .controlSize(.large)
                    Spacer()
                    Button { executePlan() } label: {
                        Label(UICopy.Plan.approveButton, systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .controlSize(.large)
                }
            }
            .padding(DesignSystem.Spacing.xl)
            .background(DesignSystem.Colors.backgroundPrimary)
            
            Divider()
            
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(plan.actions) { action in
                        PlannedActionRowView(action: action)
                    }
                }
                .padding(16)
            }
            
            HStack {
                Image(systemName: "info.circle.fill").foregroundColor(.blue)
                Text(UICopy.Plan.confidenceHint)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(16)
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
            if moveCount > 0 { Badge(text: UICopy.Plan.summaryMoved(moveCount), color: .blue) }
            if deleteCount > 0 { Badge(text: UICopy.Plan.summaryTrash(deleteCount), color: .orange) }
            if skipCount > 0 { Badge(text: UICopy.Plan.summarySkipped(skipCount), color: .secondary) }
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
        HStack(spacing: DesignSystem.Spacing.md) {
            FileThumbnailView(file: action.targetFile, size: 44, showPreviewOnTap: true)
            actionIcon
            
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Text(action.targetFile.fileName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    destinationTag
                }
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: "lightbulb.fill")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(UICopy.Plan.reason(action.reason))
                        .font(DesignSystem.Typography.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            
            Spacer()
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.cardBackground)
        .cornerRadius(DesignSystem.CornerRadius.md)
    }
    
    @ViewBuilder
    private var actionIcon: some View {
        ZStack {
            Circle()
                .fill(actionColor.opacity(0.15))
                .frame(width: 36, height: 36)
            Image(systemName: actionIconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(actionColor)
        }
    }
    
    private var actionColor: Color {
        switch action.actionType {
        case .move: return .blue
        case .delete: return .orange
        case .skip: return .secondary
        case .copy: return .green
        case .rename: return .purple
        }
    }
    
    private var actionIconName: String {
        switch action.actionType {
        case .move: return "arrow.right"
        case .delete: return "trash"
        case .skip: return "minus"
        case .copy: return "doc.on.doc"
        case .rename: return "pencil"
        }
    }
    
    @ViewBuilder
    private var destinationTag: some View {
        switch action.actionType {
        case .move(let dest):
            HStack(spacing: 4) {
                Image(systemName: "arrow.right")
                    .font(.caption2)
                Text(dest.lastPathComponent)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.blue.opacity(0.1))
            .foregroundColor(.blue)
            .cornerRadius(6)
        case .delete:
            Text("Trash")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.1))
                .foregroundColor(.orange)
                .cornerRadius(6)
        case .skip:
            Text("No action")
                .font(.caption)
                .italic()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .foregroundColor(.secondary)
                .cornerRadius(6)
        case .copy(let dest):
            HStack(spacing: 4) {
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
                Text(dest.lastPathComponent)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.green.opacity(0.1))
            .foregroundColor(.green)
            .cornerRadius(6)
        case .rename(let newName):
            HStack(spacing: 4) {
                Image(systemName: "pencil")
                    .font(.caption2)
                Text(newName)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.purple.opacity(0.1))
            .foregroundColor(.purple)
            .cornerRadius(6)
        }
    }
}

struct ExecutionResultsView: View {
    let log: ExecutionLog
    @ObservedObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(UICopy.Execution.title).font(.headline)
                        summaryText
                    }
                    Spacer()
                    HStack(spacing: 12) {
                        Button(UICopy.Execution.undoButton) { performUndo() }.buttonStyle(.bordered)
                        Button(UICopy.Execution.doneButton) {
                            appState.executionLog = nil
                            appState.scanResult = nil
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            Divider()
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

struct DuplicatesView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Duplicate Files")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("\(appState.duplicateGroups.count) groups found")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            if appState.duplicateGroups.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No duplicates found")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(appState.duplicateGroups.enumerated()), id: \.offset) { index, group in
                        Section(header: Text("Group \(index + 1) - \(group.count) files").font(.headline)) {
                            ForEach(group) { file in
                                HStack(spacing: 12) {
                                    FileThumbnailView(file: file, size: 40, showPreviewOnTap: true)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(file.fileName)
                                            .fontWeight(.medium)
                                        Text(file.fileURL.deletingLastPathComponent().path)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        if let size = file.fileSize {
                                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 700, height: 500)
    }
}

struct ExecutionEntryRowView: View {
    let entry: ExecutionLog.Entry
    
    var body: some View {
        HStack(spacing: 12) {
            outcomeIcon.frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.sourceURL.lastPathComponent).fontWeight(.medium)
                outcomeText
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
    
    @ViewBuilder
    private var outcomeIcon: some View {
        switch entry.outcome {
        case .success: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .skipped: Image(systemName: "arrow.uturn.right.circle.fill").foregroundColor(.orange)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundColor(.red)
        }
    }
    
    @ViewBuilder
    private var outcomeText: some View {
        switch entry.outcome {
        case .success:
            if let dest = entry.destinationURL {
                Text(UICopy.Execution.movedTo(dest.lastPathComponent)).font(.caption).foregroundColor(.secondary)
            } else {
                Text(UICopy.Execution.completed).font(.caption).foregroundColor(.secondary)
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
