import Foundation

// MARK: - Staleness State

/// Represents how stale the last scan results might be.
/// This is a subjective assessment based on observed events, not filesystem truth.
public enum StalenessLevel: String, Sendable, Codable {
    case fresh          // No events since last scan
    case possiblyStale  // Some events received, may warrant attention
    case stale          // Significant events or time elapsed; rescan recommended
}

/// Tracks the staleness of scan results for a specific root folder.
/// This is advisory information, not ground truth.
public struct ScanStalenessState: Sendable {
    public let rootURL: URL
    public var lastScanTime: Date?
    public var pendingEventCount: Int
    public var lastEventTime: Date?
    public var stalenessLevel: StalenessLevel
    
    public init(rootURL: URL) {
        self.rootURL = rootURL
        self.lastScanTime = nil
        self.pendingEventCount = 0
        self.lastEventTime = nil
        self.stalenessLevel = .stale // No scan yet = stale by default
    }
}

// MARK: - Scan Suggestion

/// A suggestion to rescan, including rationale.
/// The UI should present this to the user; it is NOT an automatic trigger.
public struct ScanSuggestion: Sendable {
    public let rootURL: URL
    public let reason: String
    public let urgency: Urgency
    public let timestamp: Date
    
    public enum Urgency: String, Sendable {
        case low      // User may ignore
        case medium   // Worth mentioning
        case high     // Strongly recommend rescan
    }
    
    public init(rootURL: URL, reason: String, urgency: Urgency, timestamp: Date = Date()) {
        self.rootURL = rootURL
        self.reason = reason
        self.urgency = urgency
        self.timestamp = timestamp
    }
}

// MARK: - Scan Bridge Delegate

/// Protocol for receiving scan suggestions.
/// The delegate (typically UI) decides whether to act on suggestions.
public protocol ScanBridgeDelegate: AnyObject {
    /// Called when the bridge suggests a rescan may be warranted.
    /// This is advisory. The delegate may ignore, defer, or present to user.
    func scanBridge(_ bridge: ScanBridge, suggestsRescan suggestion: ScanSuggestion)
}

// MARK: - Scan Bridge

/// Bridges filesystem events to scan staleness decisions.
///
/// Philosophy:
/// - Events indicate POSSIBLE staleness, not actual change.
/// - This bridge answers: "Is our last scan potentially out of date?"
/// - It does NOT answer: what changed, what to do, or whether files exist.
/// - Scans are NEVER triggered automatically. Only suggestions are emitted.
///
/// Contract compliance:
/// - NO automatic execution
/// - NO rule evaluation
/// - NO ActionPlan creation
/// - NO filesystem mutation
public final class ScanBridge {
    
    public weak var delegate: ScanBridgeDelegate?
    
    /// Staleness state per watched root folder.
    private var stalenessStates: [URL: ScanStalenessState] = [:]
    
    // MARK: - Tunable Heuristics
    // These thresholds are conservative and pessimistic.
    // When uncertain, we prefer inaction over noise.
    
    /// Number of events before suggesting a rescan.
    /// Why 10? Arbitrary but conservative. Single-file edits won't spam suggestions.
    private let eventCountThreshold: Int = 10
    
    /// Time since last scan before considering data stale (seconds).
    /// Why 5 minutes? Balances freshness vs. annoyance.
    private let staleTimeThreshold: TimeInterval = 300
    
    /// Minimum time between suggestions to avoid spamming (seconds).
    private let suggestionCooldown: TimeInterval = 60
    
    private var lastSuggestionTime: [URL: Date] = [:]
    
    public init() {}
    
    // MARK: - Public API
    
    /// Register a root folder for staleness tracking.
    /// Call this when the user adds a folder to watch.
    public func registerRoot(_ url: URL) {
        if stalenessStates[url] == nil {
            stalenessStates[url] = ScanStalenessState(rootURL: url)
        }
    }
    
    /// Handle an incoming filesystem event from the Observer.
    /// Updates staleness state and may emit a suggestion.
    public func handle(event: FileSystemEvent) {
        // Find which root this event belongs to
        guard let rootURL = findRoot(for: event.affectedURL) else {
            // Event is for a folder we're not tracking; ignore.
            return
        }
        
        // Update staleness state
        var state = stalenessStates[rootURL] ?? ScanStalenessState(rootURL: rootURL)
        state.pendingEventCount += 1
        state.lastEventTime = event.timestamp
        
        // Compute new staleness level
        state.stalenessLevel = computeStaleness(state: state, eventType: event.eventType)
        
        stalenessStates[rootURL] = state
        
        // Decide whether to suggest a rescan
        evaluateAndSuggest(for: rootURL, state: state, triggeringEvent: event)
    }
    
    /// Called after a scan completes to reset staleness.
    public func markScanCompleted(for rootURL: URL, at timestamp: Date = Date()) {
        guard var state = stalenessStates[rootURL] else { return }
        
        state.lastScanTime = timestamp
        state.pendingEventCount = 0
        state.lastEventTime = nil
        state.stalenessLevel = .fresh
        
        stalenessStates[rootURL] = state
    }
    
    /// Query whether a rescan should be suggested for a root.
    /// This is a pull-based alternative to the delegate callback.
    public func shouldSuggestRescan(for rootURL: URL) -> Bool {
        guard let state = stalenessStates[rootURL] else { return false }
        return state.stalenessLevel == .stale
    }
    
    /// Get current staleness state for a root (for UI display).
    public func staleness(for rootURL: URL) -> ScanStalenessState? {
        return stalenessStates[rootURL]
    }
    
    // MARK: - Internal Logic
    
    /// Find which registered root contains this URL.
    private func findRoot(for url: URL) -> URL? {
        // Simple prefix matching. In a real app, use standardized paths.
        for root in stalenessStates.keys {
            if url.path.hasPrefix(root.path) {
                return root
            }
        }
        return nil
    }
    
    /// Compute staleness level based on heuristics.
    /// Why conservative? Because suggesting unnecessary rescans erodes trust.
    /// Why pessimistic? Because missing a needed rescan is worse than one extra.
    private func computeStaleness(state: ScanStalenessState, eventType: FileSystemEvent.EventType) -> StalenessLevel {
        // If never scanned, always stale
        guard let lastScan = state.lastScanTime else {
            return .stale
        }
        
        let timeSinceScan = Date().timeIntervalSince(lastScan)
        
        // Time-based staleness: if it's been a while, we're stale
        if timeSinceScan > staleTimeThreshold {
            return .stale
        }
        
        // Event-count staleness: many events suggest significant change
        if state.pendingEventCount >= eventCountThreshold {
            return .stale
        }
        
        // Event-type weighting: deletes/renames are more significant than modifies
        // A single delete or rename bumps us to possiblyStale immediately
        if eventType == .removed || eventType == .renamed {
            if state.pendingEventCount >= 3 {
                return .stale
            }
            return .possiblyStale
        }
        
        // Some events but not enough to be confident
        if state.pendingEventCount > 0 {
            return .possiblyStale
        }
        
        return .fresh
    }
    
    /// Decide whether to emit a suggestion. Respects cooldown to avoid spam.
    private func evaluateAndSuggest(for rootURL: URL, state: ScanStalenessState, triggeringEvent: FileSystemEvent) {
        // Only suggest when stale (not for possiblyStale — that's just awareness)
        guard state.stalenessLevel == .stale else { return }
        
        // Respect cooldown: don't spam suggestions
        if let lastTime = lastSuggestionTime[rootURL] {
            let elapsed = Date().timeIntervalSince(lastTime)
            if elapsed < suggestionCooldown {
                return
            }
        }
        
        // Build suggestion with human-readable reason
        let reason = buildReason(state: state, triggeringEvent: triggeringEvent)
        let urgency = determineUrgency(state: state)
        
        let suggestion = ScanSuggestion(
            rootURL: rootURL,
            reason: reason,
            urgency: urgency
        )
        
        lastSuggestionTime[rootURL] = Date()
        
        delegate?.scanBridge(self, suggestsRescan: suggestion)
    }
    
    /// Build a human-readable reason for the suggestion.
    private func buildReason(state: ScanStalenessState, triggeringEvent: FileSystemEvent) -> String {
        if state.pendingEventCount >= eventCountThreshold {
            return "\(state.pendingEventCount) changes detected since last scan."
        }
        
        if let lastScan = state.lastScanTime {
            let minutes = Int(Date().timeIntervalSince(lastScan) / 60)
            if minutes > 5 {
                return "Last scan was \(minutes) minutes ago and changes have occurred."
            }
        }
        
        switch triggeringEvent.eventType {
        case .removed:
            return "A file was deleted. Scan data may be outdated."
        case .renamed:
            return "A file was renamed. Scan data may be outdated."
        case .created:
            return "New files detected. Consider rescanning."
        case .modified:
            return "Files have been modified since last scan."
        }
    }
    
    /// Determine urgency based on staleness indicators.
    private func determineUrgency(state: ScanStalenessState) -> ScanSuggestion.Urgency {
        if state.pendingEventCount >= eventCountThreshold * 2 {
            return .high
        }
        if state.pendingEventCount >= eventCountThreshold {
            return .medium
        }
        return .low
    }
}

// MARK: - Example Usage

public func scanBridgeExample() {
    print("--- Scan Bridge Example ---")
    
    class ExampleDelegate: ScanBridgeDelegate {
        func scanBridge(_ bridge: ScanBridge, suggestsRescan suggestion: ScanSuggestion) {
            print("💡 Suggestion: \(suggestion.reason)")
            print("   Urgency: \(suggestion.urgency.rawValue)")
            print("   Folder: \(suggestion.rootURL.lastPathComponent)")
        }
    }
    
    let bridge = ScanBridge()
    let delegate = ExampleDelegate()
    bridge.delegate = delegate
    
    let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    
    // 1. Register and mark initial scan complete
    bridge.registerRoot(downloadsURL)
    bridge.markScanCompleted(for: downloadsURL)
    print("Initial state: \(bridge.staleness(for: downloadsURL)?.stalenessLevel.rawValue ?? "unknown")")
    
    // 2. Simulate events arriving
    for i in 1...12 {
        let event = FileSystemEvent(
            affectedURL: downloadsURL.appendingPathComponent("file\(i).txt"),
            eventType: .created
        )
        bridge.handle(event: event)
        print("After event \(i): \(bridge.staleness(for: downloadsURL)?.stalenessLevel.rawValue ?? "unknown")")
    }
    
    // 3. After rescan, state resets
    bridge.markScanCompleted(for: downloadsURL)
    print("After rescan: \(bridge.staleness(for: downloadsURL)?.stalenessLevel.rawValue ?? "unknown")")
}
