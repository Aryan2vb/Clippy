import SwiftUI
import ClippyCore
import ClippyEngine

// MARK: - Organize View

/// The main workflow screen implementing a 4-step pipeline:
///   Step 1 — Folder Selection (drop zone)
///   Step 2 — Scan Results (file list)
///   Step 3 — Action Plan Review (trust model heart)
///   Step 4 — Execution Results (with undo)
struct OrganizeView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 0) {
            // Quick actions toolbar
            quickActionsToolbar
            
            // Header
            OrganizeHeaderView(appState: appState)
            Divider()
            
            // Step-based content
            Group {
                if appState.selectedFolderURL == nil {
                    // Step 1: Folder Selection
                    DropZoneView(
                        selectedFolderURL: $appState.selectedFolderURL
                    ) { url in
                        appState.scanBridge.registerRoot(url)
                        appState.stalenessState = ScanStalenessState(rootURL: url)
                        appState.scanResult = nil
                        appState.actionPlan = nil
                        appState.executionLog = nil
                        appState.cancellationMessage = nil
                    }
                } else if appState.isScanning {
                    ScanningStateView(appState: appState)
                } else if appState.isExecuting {
                    ExecutingStateView(appState: appState)
                } else if let log = appState.executionLog {
                    // Step 4: Execution Results
                    ExecutionResultsView(log: log, appState: appState)
                } else if let plan = appState.actionPlan {
                    // Step 3: Action Plan Review
                    PlanPreviewView(plan: plan, appState: appState)
                } else if let result = appState.scanResult {
                    // Step 2: Scan Results
                    ScanResultsView(result: result, appState: appState)
                } else {
                    // Ready to scan (folder selected, no scan yet)
                    ReadyToScanView(appState: appState)
                }
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
    
    @State private var showExecuteConfirmation = false
    
    // MARK: - Quick Actions Toolbar
    
    @ViewBuilder
    private var quickActionsToolbar: some View {
        HStack(spacing: 12) {
            // Step indicator pills
            StepIndicator(
                currentStep: currentStep,
                isScanning: appState.isScanning,
                isExecuting: appState.isExecuting
            )
            
            Spacer()
            
            Button {
                appState.startScan()
            } label: {
                Label("Scan", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Scan selected folder (⌘R)")
            .disabled(appState.selectedFolderURL == nil || appState.isScanning || appState.isExecuting || appState.executionLog != nil)
            
            Divider()
                .frame(height: 20)
            
            Button {
                appState.createPlan()
            } label: {
                Label("Create Plan", systemImage: "list.bullet.rectangle")
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .help("Evaluate rules against scanned files (⌘⇧E)")
            .disabled(appState.scanResult == nil || appState.actionPlan != nil)
            
            Button {
                showExecuteConfirmation = true
            } label: {
                Label("Execute", systemImage: "play.fill")
            }
            .keyboardShortcut(.return, modifiers: .command)
            .help("Execute the approved action plan (⌘↩)")
            .disabled(appState.actionPlan == nil || appState.isExecuting || hasUnresolvedConflicts)
            .buttonStyle(.borderedProminent)
            .confirmationDialog(
                "Execute \(appState.actionPlan?.actions.count ?? 0) actions?",
                isPresented: $showExecuteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Execute", role: .destructive) { appState.executePlan() }
                Button("Cancel", role: .cancel) { }
            }
            
            Button {
                appState.performUndo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(appState.executionLog == nil)
            
            if appState.selectedFolderURL != nil {
                Divider()
                    .frame(height: 20)
                
                Button {
                    appState.selectedFolderURL = nil
                    appState.scanResult = nil
                    appState.actionPlan = nil
                    appState.executionLog = nil
                    appState.stalenessState = nil
                    appState.cancellationMessage = nil
                } label: {
                    Label("Change Folder", systemImage: "folder.badge.plus")
                }
                .help("Select a different folder (⌘O)")
                .keyboardShortcut("o", modifiers: .command)
                .disabled(appState.isScanning || appState.isExecuting)
            }
            
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
    
    // MARK: - State Helpers
    
    private var currentStep: Int {
        if appState.executionLog != nil { return 4 }
        if appState.actionPlan != nil { return 3 }
        if appState.scanResult != nil { return 2 }
        if appState.selectedFolderURL != nil { return 1 }
        return 0
    }
    
    private var hasUnresolvedConflicts: Bool {
        appState.actionPlan?.actions.contains { $0.isConflict } ?? false
    }
}

// MARK: - Step Indicator

/// Visual indicator showing the current step in the 4-step pipeline.
struct StepIndicator: View {
    let currentStep: Int
    let isScanning: Bool
    let isExecuting: Bool
    
    private let steps = [
        (icon: "folder", label: "Select"),
        (icon: "magnifyingglass", label: "Scan"),
        (icon: "checklist", label: "Review"),
        (icon: "play.fill", label: "Execute")
    ]
    
    var body: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: DesignSystem.Spacing.xxs) {
                    Image(systemName: stepIcon(for: index + 1, step: step))
                        .font(.caption2)
                    Text(step.label)
                        .font(DesignSystem.Typography.captionSmall)
                }
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, DesignSystem.Spacing.xxs)
                .background(stepBackground(for: index + 1))
                .foregroundColor(stepForeground(for: index + 1))
                .cornerRadius(DesignSystem.CornerRadius.full)
                
                if index < steps.count - 1 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary.opacity(0.5))
                }
            }
        }
    }
    
    private func stepIcon(for step: Int, step info: (icon: String, label: String)) -> String {
        if step < currentStep {
            return "checkmark.circle.fill"
        }
        if step == currentStep && (isScanning || isExecuting) {
            return "arrow.triangle.2.circlepath"
        }
        return info.icon
    }
    
    private func stepBackground(for step: Int) -> Color {
        if step == currentStep {
            return Color.accentColor.opacity(0.2)
        }
        if step < currentStep {
            return Color.green.opacity(0.1)
        }
        return Color.secondary.opacity(0.08)
    }
    
    private func stepForeground(for step: Int) -> Color {
        if step == currentStep { return .accentColor }
        if step < currentStep { return .green }
        return .secondary
    }
}

// MARK: - Organize Header

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



// MARK: - Step 1: Ready to Scan (folder selected, no scan)

struct ReadyToScanView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 24) {
            // Animated icon
            ScanReadyAnimationView()
            
            VStack(spacing: 8) {
                Text(UICopy.EmptyState.readyToScanTitle)
                    .font(.title3)
                    .fontWeight(.medium)
                
                Text(UICopy.EmptyState.readyToScanBody)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                
                if let msg = appState.cancellationMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    .padding(.top, 4)
                }
            }
            
            // Main action button
            Button {
                appState.startScan()
            } label: {
                Label(UICopy.EmptyState.startScanButton, systemImage: "magnifyingglass")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("r", modifiers: .command)
            
            // Quick stats
            HStack(spacing: 16) {
                QuickStatView(icon: "doc.badge.gearshape", value: "\(appState.rules.filter(\.isEnabled).count)", label: "active rules")
                QuickStatView(icon: "clock.arrow.circlepath", value: formatLastScanTime(), label: "last scan")
            }
            .padding(.top, 8)
            
            // Helpful tip
            ScanReadyTipView()
                .padding(.top, 16)
            
            // Change folder option
            Button {
                clearFolderSelection()
            } label: {
                Label("Choose Different Folder", systemImage: "folder.badge.plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
            .padding(.top, 8)
            .help("Select a different folder to organize")
            
            Spacer().frame(height: 20)
            
            // Keyboard shortcuts hint
            Text("⌘R to scan  ·  ⌘⇧E to evaluate  ·  ⌘↩ to execute")
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func formatLastScanTime() -> String {
        guard let lastScan = appState.stalenessState?.lastScanTime else {
            return "Never"
        }
        let interval = Date().timeIntervalSince(lastScan)
        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m ago"
        } else if interval < 86400 {
            return "\(Int(interval / 3600))h ago"
        } else {
            return "\(Int(interval / 86400))d ago"
        }
    }
    
    private func clearFolderSelection() {
        appState.selectedFolderURL = nil
        appState.scanResult = nil
        appState.actionPlan = nil
        appState.executionLog = nil
        appState.stalenessState = nil
        appState.cancellationMessage = nil
    }
}

// Quick stat view for ready to scan
struct QuickStatView: View {
    let icon: String
    let value: String
    let label: String
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }
}

// Animated ready to scan icon
struct ScanReadyAnimationView: View {
    @State private var isAnimating = false
    
    var body: some View {
        ZStack {
            // Pulsing circles
            ForEach(0..<3) { index in
                Circle()
                    .stroke(Color.accentColor.opacity(0.3 - Double(index) * 0.1), lineWidth: 2)
                    .frame(width: 60 + CGFloat(index * 20), height: 60 + CGFloat(index * 20))
                    .scaleEffect(isAnimating ? 1.1 : 1.0)
                    .opacity(isAnimating ? 0.5 : 1.0)
                    .animation(.easeInOut(duration: 2.0).repeatForever().delay(Double(index) * 0.3), value: isAnimating)
            }
            
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 36, weight: .medium))
                .foregroundColor(.accentColor)
        }
        .frame(width: 100, height: 100)
        .onAppear {
            isAnimating = true
        }
    }
}

// Tips for ready to scan
struct ScanReadyTipView: View {
    let tips = [
        "💡 Drag and drop a folder to select it",
        "💡 Enable only the rules you need for faster scanning",
        "💡 Use the Rules tab to customize file organization",
        "💡 All changes can be undone from the History tab"
    ]
    
    @State private var currentTipIndex = 0
    @State private var timer: Timer? = nil
    
    var body: some View {
        Text(tips[currentTipIndex])
            .font(.caption)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 350)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)
            .onAppear {
                timer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: true) { _ in
                    withAnimation {
                        currentTipIndex = (currentTipIndex + 1) % tips.count
                    }
                }
            }
            .onDisappear {
                timer?.invalidate()
            }
    }
}

// MARK: - Scanning State

struct ScanningStateView: View {
    @ObservedObject var appState: AppState
    @State private var startTime: Date = Date()
    @State private var timer: Timer? = nil
    @State private var elapsedTime: TimeInterval = 0
    
    var body: some View {
        VStack(spacing: 24) {
            // Animated scanning icon
            ScanningAnimationView()
            
            VStack(spacing: 8) {
                Text(UICopy.Progress.scanningTitle)
                    .font(.headline)
                
                if let progress = appState.scanProgress {
                    // Progress bar
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.2))
                                .frame(height: 8)
                            
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.accentColor)
                                .frame(width: calculateProgressWidth(geometry), height: 8)
                                .animation(.linear(duration: 0.3), value: progress.filesFound)
                        }
                    }
                    .frame(width: 300, height: 8)
                    
                    // File count with formatted numbers
                    HStack(spacing: 4) {
                        Text("\(progress.filesFound.formatted())")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                        Text("files found")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    // Current path with icon
                    if let currentPath = progress.currentPath {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(currentPath)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: 400)
                    }
                    
                    // ETA calculation
                    if progress.filesFound > 10 {
                        Text(calculateETA(filesFound: progress.filesFound))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            // Tips during scanning
            ScanningTipView()
                .padding(.top, 8)
            
            Button(role: .cancel) {
                timer?.invalidate()
                appState.cancelScan()
            } label: {
                Label("Cancel Scan", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            startTime = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                elapsedTime = Date().timeIntervalSince(startTime)
            }
        }
        .onDisappear {
            timer?.invalidate()
        }
    }
    
    private func calculateProgressWidth(_ geometry: GeometryProxy) -> CGFloat {
        guard let progress = appState.scanProgress else { return 0 }
        // Estimate total based on current rate (files per second)
        let estimatedTotal = max(progress.filesFound, 100)
        let percentage = min(CGFloat(progress.filesFound) / CGFloat(estimatedTotal), 0.95)
        return geometry.size.width * percentage
    }
    
    private func calculateETA(filesFound: Int) -> String {
        let rate = Double(filesFound) / max(elapsedTime, 1.0)
        if rate < 1 {
            return "Calculating time remaining..."
        }
        // Estimate completion based on typical folder sizes
        let estimatedRemaining = max(0, Int(Double(filesFound) * 0.2))
        let secondsRemaining = Double(estimatedRemaining) / rate
        
        if secondsRemaining < 5 {
            return "Almost done..."
        } else if secondsRemaining < 60 {
            return "About \(Int(secondsRemaining)) seconds remaining"
        } else {
            let minutes = Int(secondsRemaining / 60)
            return "About \(minutes) minute\(minutes == 1 ? "" : "s") remaining"
        }
    }
}

// Animated scanning icon
struct ScanningAnimationView: View {
    @State private var isAnimating = false
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(0.2), lineWidth: 4)
                .frame(width: 80, height: 80)
            
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 80, height: 80)
                .rotationEffect(Angle(degrees: isAnimating ? 360 : 0))
                .animation(.linear(duration: 1.0).repeatForever(autoreverses: false), value: isAnimating)
            
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(.accentColor)
        }
        .onAppear {
            isAnimating = true
        }
    }
}

// Tips during scanning
struct ScanningTipView: View {
    let tips = [
        "💡 Tip: You can cancel anytime and resume later",
        "💡 Tip: Large folders may take a few minutes",
        "💡 Tip: Duplicate detection happens after scanning",
        "💡 Tip: Files are never modified during scanning"
    ]
    
    @State private var currentTipIndex = 0
    @State private var timer: Timer? = nil
    
    var body: some View {
        Text(tips[currentTipIndex])
            .font(.caption)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 350)
            .onAppear {
                timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
                    withAnimation {
                        currentTipIndex = (currentTipIndex + 1) % tips.count
                    }
                }
            }
            .onDisappear {
                timer?.invalidate()
            }
    }
}

// MARK: - Executing State

struct ExecutingStateView: View {
    @ObservedObject var appState: AppState
    @State private var startTime: Date = Date()
    @State private var timer: Timer? = nil
    @State private var elapsedTime: TimeInterval = 0
    
    var body: some View {
        VStack(spacing: 24) {
            // Animated gear icon
            ExecutingAnimationView()
            
            VStack(spacing: 8) {
                Text(UICopy.Progress.executingTitle)
                    .font(.headline)
                
                if let log = appState.executionLog {
                    // Show progress based on completed entries
                    let completed = log.entries.filter { $0.outcome != .skipped }.count
                    let total = log.entries.count
                    let progress = total > 0 ? Double(completed) / Double(total) : 0
                    
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.2))
                                .frame(height: 8)
                            
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.green)
                                .frame(width: geometry.size.width * CGFloat(progress), height: 8)
                                .animation(.linear(duration: 0.3), value: progress)
                        }
                    }
                    .frame(width: 300, height: 8)
                    
                    Text("\(completed) of \(total) actions completed")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                    
                    // Show current action if available
                    if let currentEntry = log.entries.first(where: { $0.outcome == .skipped }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.right.circle")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Processing: \(currentEntry.sourceURL.lastPathComponent)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: 350)
                    }
                } else {
                    Text("Preparing actions...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                if elapsedTime > 3 {
                    Text("Elapsed: \(formatElapsedTime(elapsedTime))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Safety reminder
            HStack(spacing: 6) {
                Image(systemName: "shield.fill")
                    .font(.caption)
                    .foregroundColor(.green)
                Text("All changes can be undone after completion")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            startTime = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                elapsedTime = Date().timeIntervalSince(startTime)
            }
        }
        .onDisappear {
            timer?.invalidate()
        }
    }
    
    private func formatElapsedTime(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }
}

struct ExecutingAnimationView: View {
    @State private var isAnimating = false
    
    var body: some View {
        ZStack {
            // Outer ring
            Circle()
                .stroke(Color.green.opacity(0.2), lineWidth: 4)
                .frame(width: 80, height: 80)
            
            // Rotating gear
            Image(systemName: "gear")
                .font(.system(size: 40))
                .foregroundColor(.green)
                .rotationEffect(Angle(degrees: isAnimating ? 360 : 0))
                .animation(.linear(duration: 2.0).repeatForever(autoreverses: false), value: isAnimating)
            
            // Pulsing dots
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                        .opacity(isAnimating ? 1.0 : 0.3)
                        .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(index) * 0.2), value: isAnimating)
                }
            }
            .offset(y: 50)
        }
        .onAppear {
            isAnimating = true
        }
    }
}

// MARK: - Step 2: Scan Results

struct ScanResultsView: View {
    let result: ScanResult
    @ObservedObject var appState: AppState
    @State private var showSkippedFolders = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with file count and action
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
                Button(UICopy.Plan.createPlanButton) { appState.createPlan() }
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
                
                // Skipped folders section
                if !result.skippedFolders.isEmpty {
                    SkippedFoldersSection(
                        skippedFolders: result.skippedFolders,
                        isExpanded: $showSkippedFolders
                    )
                }
            }
            .listStyle(.inset)
        }
    }
    
    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
    }
}

// MARK: - Skipped Folders Section

struct SkippedFoldersSection: View {
    let skippedFolders: [SkippedFolder]
    @Binding var isExpanded: Bool
    
    private var uniqueFolderNames: [String] {
        Set(skippedFolders.map { $0.url.lastPathComponent }).sorted()
    }
    
    var body: some View {
        Section {
            if isExpanded {
                ForEach(skippedFolders) { folder in
                    HStack(spacing: 8) {
                        Image(systemName: "folder.badge.minus")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.url.lastPathComponent)
                                .font(.caption)
                            Text(folder.reason)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("Skipped \(skippedFolders.count) folder\(skippedFolders.count == 1 ? "" : "s")")
                        .font(.caption)
                        .fontWeight(.medium)
                    
                    if !uniqueFolderNames.isEmpty {
                        Text("(\(uniqueFolderNames.joined(separator: ", ")))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    
                    Spacer()
                    
                    Text(isExpanded ? "Hide" : "Show")
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                }
                .foregroundColor(.primary)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
        }
        .listRowBackground(Color.orange.opacity(0.05))
    }
}

// MARK: - File Row

struct FileRowView: View {
    let file: FileDescriptor
    
    var body: some View {
        HStack(spacing: 12) {
            FileThumbnailView(file: file, size: 40, showPreviewOnTap: true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Text(file.fileName).lineLimit(1)
                    
                    // Extension badge
                    if !file.fileExtension.isEmpty && !file.isDirectory {
                        Text(".\(file.fileExtension)")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.1))
                            .foregroundColor(.accentColor)
                            .cornerRadius(4)
                    }
                }
                
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Text(file.fileURL.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    
                    if let modified = file.modifiedAt {
                        Text("·")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Text(modified.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
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

// MARK: - Step 3: Plan Preview (Heart of the Trust Model)

struct PlanPreviewView: View {
    let plan: ActionPlan
    @ObservedObject var appState: AppState
    
    /// Actions that are conflicts
    private var conflictActions: [PlannedAction] {
        plan.actions.filter { $0.isConflict }
    }
    
    /// Non-conflict actions grouped by action type
    private var normalActions: [PlannedAction] {
        plan.actions.filter { !$0.isConflict }
    }
    
    /// Grouped normal actions by type
    private var groupedActions: [(String, [PlannedAction])] {
        let groups = Dictionary(grouping: normalActions) { action -> String in
            switch action.actionType {
            case .move: return "Move"
            case .copy: return "Copy"
            case .delete: return "Delete"
            case .rename: return "Rename"
            case .skip: return "Skip"
            }
        }
        let order = ["Move", "Copy", "Delete", "Rename", "Skip"]
        return order.compactMap { key in
            guard let actions = groups[key], !actions.isEmpty else { return nil }
            return (key, actions)
        }
    }
    
    private var hasConflicts: Bool {
        !conflictActions.isEmpty
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
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
                }
                
                // Action buttons
                HStack(spacing: DesignSystem.Spacing.md) {
                    Button(UICopy.Plan.cancelButton) { appState.actionPlan = nil }
                        .buttonStyle(SecondaryButtonStyle())
                        .controlSize(.large)
                        .keyboardShortcut(.escape, modifiers: [])
                    Spacer()
                    Button { appState.executePlan() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                            Text(UICopy.Plan.approveButton)
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                }
                .disabled(hasConflicts)
                .help(hasConflicts ? "Resolve conflicts before executing" : "")
            }
            .padding(DesignSystem.Spacing.xl)
            .background(DesignSystem.Colors.backgroundPrimary)
            
            Divider()
            
            // Plan content
            ScrollView {
                LazyVStack(spacing: DesignSystem.Spacing.md) {
                    // Conflicts section (shown first if any)
                    if hasConflicts {
                        ConflictSectionHeader(count: conflictActions.count)
                        
                        ForEach(conflictActions) { action in
                            ConflictWarningRow(action: action)
                                .padding(.horizontal, DesignSystem.Spacing.lg)
                        }
                        
                        Divider()
                            .padding(.vertical, DesignSystem.Spacing.sm)
                    }
                    
                    // Grouped normal actions
                    ForEach(groupedActions, id: \.0) { groupName, actions in
                        Section {
                            ForEach(actions) { action in
                                PlannedActionRowView(action: action)
                                    .padding(.horizontal, DesignSystem.Spacing.lg)
                            }
                        } header: {
                            HStack {
                                ActionChip(actionType: actions.first!.actionType)
                                Text("\(actions.count) file\(actions.count == 1 ? "" : "s")")
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, DesignSystem.Spacing.lg)
                            .padding(.top, DesignSystem.Spacing.sm)
                        }
                    }
                }
                .padding(.vertical, DesignSystem.Spacing.md)
            }
            
            // Summary bar
            Divider()
            SummaryBar(plan: plan, conflictCount: conflictActions.count)
            
            // Info hint
            HStack {
                Image(systemName: "info.circle.fill").foregroundColor(.blue)
                Text(UICopy.Plan.confidenceHint)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
}

// MARK: - Planned Action Row

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
                    
                    // Action chip
                    ActionChip(actionType: action.actionType)
                    
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
        case .delete: return Color(NSColor.systemRed)
        case .skip: return .secondary
        case .copy: return .green
        case .rename: return .yellow
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
        case .delete:
            Text("Trash")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.1))
                .foregroundColor(.red)
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
            .background(Color.yellow.opacity(0.1))
            .foregroundColor(.yellow)
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
        }
    }
}

// MARK: - Step 4: Execution Results

struct ExecutionResultsView: View {
    let log: ExecutionLog
    @ObservedObject var appState: AppState
    @State private var showUndoConfirmation = false
    
    private var successCount: Int {
        log.entries.filter { $0.outcome == .success }.count
    }
    
    private var failCount: Int {
        log.entries.filter { $0.outcome == .failed }.count
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Results header
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(UICopy.Execution.title).font(.headline)
                        summaryText
                    }
                    Spacer()
                    HStack(spacing: 12) {
                        // Prominent Undo button
                        Button {
                            showUndoConfirmation = true
                        } label: {
                            Label(UICopy.Execution.undoButton, systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderedProminent)
                        
                        Button(UICopy.Execution.doneButton) {
                            appState.executionLog = nil
                            appState.scanResult = nil
                        }
                        .buttonStyle(.bordered)
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
        .alert("Undo All Changes?", isPresented: $showUndoConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Undo All", role: .destructive) {
                performUndo()
            }
        } message: {
            Text("This will restore all files to their original locations. This action cannot be undone.")
        }
    }
    
    @ViewBuilder
    private var summaryText: some View {
        if failCount > 0 {
            Text(UICopy.Execution.partialFailure)
                .font(.caption)
                .foregroundColor(.orange)
        } else {
            Text(UICopy.Execution.successSummary(successCount))
                .font(.caption)
                .foregroundColor(.green)
        }
    }
    
    private func performUndo() {
        appState.performUndo()
    }
}

// MARK: - Execution Entry Row

struct ExecutionEntryRowView: View {
    let entry: ExecutionLog.Entry
    @State private var showDetails = false
    
    var body: some View {
        HStack(spacing: 12) {
            outcomeIcon.frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.sourceURL.lastPathComponent).fontWeight(.medium)
                    
                    // Status badge for failed items
                    if entry.outcome == .failed {
                        Text("Failed")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.1))
                            .foregroundColor(.red)
                            .cornerRadius(4)
                    }
                }
                
                outcomeText
                
                // Recovery suggestion for failed items
                if entry.outcome == .failed {
                    recoverySuggestion
                        .padding(.top, 2)
                }
            }
            Spacer()
            
            // Details button for errors
            if entry.outcome == .failed || entry.outcome == .skipped {
                Button {
                    showDetails.toggle()
                } label: {
                    Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .background(entry.outcome == .failed ? Color.red.opacity(0.05) : Color.clear)
        .cornerRadius(6)
        
        if showDetails {
            detailsView
                .transition(.opacity)
        }
    }
    
    @ViewBuilder
    private var detailsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = entry.message, !message.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "text.quote")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
            
            // Full path
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "folder")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(entry.sourceURL.path)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Spacer()
            }
            
            // Recovery actions
            if entry.outcome == .failed {
                HStack(spacing: 8) {
                    Button {
                        // Retry this specific action
                        // This would need to be wired through AppState
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Button {
                        // Show in Finder
                        NSWorkspace.shared.activateFileViewerSelecting([entry.sourceURL])
                    } label: {
                        Label("Show in Finder", systemImage: "arrow.up.right")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.top, 4)
            }
        }
        .padding(.leading, 40)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }
    
    @ViewBuilder
    private var recoverySuggestion: some View {
        if let message = entry.message?.lowercased() {
            if message.contains("permission") || message.contains("denied") {
                Text("💡 Try granting Clippy full disk access in System Settings > Privacy & Security")
                    .font(.caption2)
                    .foregroundColor(.orange)
            } else if message.contains("in use") || message.contains("busy") {
                Text("💡 Close any apps using this file, then retry")
                    .font(.caption2)
                    .foregroundColor(.orange)
            } else if message.contains("exists") {
                Text("💡 A file with this name already exists at the destination")
                    .font(.caption2)
                    .foregroundColor(.orange)
            } else if message.contains("not found") || message.contains("missing") {
                Text("💡 The file may have been moved or deleted")
                    .font(.caption2)
                    .foregroundColor(.orange)
            } else if message.contains("disk full") || message.contains("space") {
                Text("💡 Free up disk space and try again")
                    .font(.caption2)
                    .foregroundColor(.orange)
            } else {
                Text("💡 Check the error details below for more information")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
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

// MARK: - Duplicates View

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
