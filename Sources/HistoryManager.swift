import Foundation
import AppKit

// MARK: - History Item Model

/// Represents a single file operation recorded in history.
/// Contains all information needed to display what happened and where files are now.
public struct HistoryItem: Identifiable, Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let actionType: HistoryActionType
    public let fileName: String
    public let originalPath: String
    public let currentPath: String?
    public let outcome: HistoryOutcome
    public let ruleName: String?
    public let message: String?
    
    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        actionType: HistoryActionType,
        fileName: String,
        originalPath: String,
        currentPath: String?,
        outcome: HistoryOutcome,
        ruleName: String? = nil,
        message: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.actionType = actionType
        self.fileName = fileName
        self.originalPath = originalPath
        self.currentPath = currentPath
        self.outcome = outcome
        self.ruleName = ruleName
        self.message = message
    }
}

/// Type of action performed on a file
public enum HistoryActionType: String, Codable, Sendable {
    case moved = "Moved"
    case copied = "Copied"
    case deleted = "Deleted"
    case renamed = "Renamed"
    case skipped = "Skipped"
    
    public var icon: String {
        switch self {
        case .moved: return "arrow.right.circle.fill"
        case .copied: return "doc.on.doc.fill"
        case .deleted: return "trash.circle.fill"
        case .renamed: return "pencil.circle.fill"
        case .skipped: return "minus.circle.fill"
        }
    }
    
    public var color: String {
        switch self {
        case .moved: return "blue"
        case .copied: return "green"
        case .deleted: return "orange"
        case .renamed: return "purple"
        case .skipped: return "gray"
        }
    }
}

/// Outcome of the history action
public enum HistoryOutcome: String, Codable, Sendable {
    case success = "Success"
    case failed = "Failed"
    case skipped = "Skipped"
}

// MARK: - History Session

/// Groups multiple history items from a single execution session
public struct HistorySession: Identifiable, Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let folderPath: String
    public var items: [HistoryItem]
    
    public var successCount: Int {
        items.filter { $0.outcome == .success }.count
    }
    
    public var failedCount: Int {
        items.filter { $0.outcome == .failed }.count
    }
    
    public var skippedCount: Int {
        items.filter { $0.outcome == .skipped }.count
    }
    
    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        folderPath: String,
        items: [HistoryItem] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.folderPath = folderPath
        self.items = items
    }
}

// MARK: - History Manager

/// Manages persistence and retrieval of file operation history.
/// Stores history in a JSON file in the app's Application Support directory.
@MainActor
public final class HistoryManager: ObservableObject {
    @Published public private(set) var sessions: [HistorySession] = []
    
    private let fileManager = FileManager.default
    private let historyFileName = "file_scanner_history.json"
    
    public init() {
        loadHistory()
    }
    
    // MARK: - Public Methods
    
    /// Records a new history session from an execution log
    public func recordSession(from log: ExecutionLog, folderPath: String) {
        var items: [HistoryItem] = []
        
        for entry in log.entries {
            let actionType = determineActionType(from: entry)
            let outcome = mapOutcome(entry.outcome)
            
            let item = HistoryItem(
                id: entry.actionId,
                timestamp: entry.timestamp,
                actionType: actionType,
                fileName: entry.sourceURL.lastPathComponent,
                originalPath: entry.sourceURL.path,
                currentPath: entry.destinationURL?.path,
                outcome: outcome,
                message: entry.message
            )
            items.append(item)
        }
        
        let session = HistorySession(
            id: log.planId,
            timestamp: log.timestamp,
            folderPath: folderPath,
            items: items
        )
        
        sessions.insert(session, at: 0)
        saveHistory()
    }
    
    /// Clears all history
    public func clearHistory() {
        sessions.removeAll()
        saveHistory()
    }
    
    /// Deletes a specific session
    public func deleteSession(_ session: HistorySession) {
        sessions.removeAll { $0.id == session.id }
        saveHistory()
    }
    
    /// Checks if a file still exists at its recorded location
    public func fileExists(at path: String?) -> Bool {
        guard let path = path else { return false }
        return fileManager.fileExists(atPath: path)
    }
    
    /// Opens the file location in Finder
    public func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }
    
    // MARK: - Undo Operations
    
    /// Result of an undo operation
    public struct UndoResult {
        public let sessionId: UUID
        public let totalItems: Int
        public let restoredCount: Int
        public let skippedCount: Int
        public let failedCount: Int
        public var details: [UndoItemResult]
        
        public var isFullyRestored: Bool {
            restoredCount == totalItems
        }
        
        public var summary: String {
            if isFullyRestored {
                return "All \(totalItems) files restored successfully"
            } else {
                var parts: [String] = []
                if restoredCount > 0 { parts.append("\(restoredCount) restored") }
                if skippedCount > 0 { parts.append("\(skippedCount) skipped") }
                if failedCount > 0 { parts.append("\(failedCount) failed") }
                return parts.joined(separator: ", ")
            }
        }
    }
    
    public struct UndoItemResult {
        public let fileName: String
        public let outcome: UndoOutcome
        public let message: String
    }
    
    public enum UndoOutcome {
        case restored
        case skipped
        case failed
    }
    
    /// Undoes all actions in a history session, restoring files to their original locations
    public func undoSession(_ session: HistorySession) -> UndoResult {
        var details: [UndoItemResult] = []
        var restoredCount = 0
        var skippedCount = 0
        var failedCount = 0
        
        // Process items in reverse order (last action first)
        for item in session.items.reversed() {
            let result = undoItem(item)
            details.append(result)
            
            switch result.outcome {
            case .restored: restoredCount += 1
            case .skipped: skippedCount += 1
            case .failed: failedCount += 1
            }
        }
        
        // Mark session as undone by updating it
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            var updatedSession = sessions[index]
            // Update items to reflect they've been undone
            updatedSession.items = updatedSession.items.map { item in
                HistoryItem(
                    id: item.id,
                    timestamp: item.timestamp,
                    actionType: item.actionType,
                    fileName: item.fileName,
                    originalPath: item.originalPath,
                    currentPath: item.originalPath, // Now back at original
                    outcome: .skipped, // Mark as undone
                    ruleName: item.ruleName,
                    message: "Undone - restored to original location"
                )
            }
            sessions[index] = updatedSession
            saveHistory()
        }
        
        return UndoResult(
            sessionId: session.id,
            totalItems: session.items.count,
            restoredCount: restoredCount,
            skippedCount: skippedCount,
            failedCount: failedCount,
            details: details
        )
    }
    
    /// Undoes a single history item
    public func undoItem(_ item: HistoryItem) -> UndoItemResult {
        // Skip if the action was not successful originally
        guard item.outcome == .success else {
            return UndoItemResult(
                fileName: item.fileName,
                outcome: .skipped,
                message: "Original action did not succeed; nothing to undo"
            )
        }
        
        let originalURL = URL(fileURLWithPath: item.originalPath)
        
        switch item.actionType {
        case .moved, .renamed, .copied:
            return undoMoveOrCopy(item: item, originalURL: originalURL)
        case .deleted:
            return undoDelete(item: item, originalURL: originalURL)
        case .skipped:
            return UndoItemResult(
                fileName: item.fileName,
                outcome: .skipped,
                message: "No action was taken; nothing to undo"
            )
        }
    }
    
    private func undoMoveOrCopy(item: HistoryItem, originalURL: URL) -> UndoItemResult {
        guard let currentPath = item.currentPath else {
            return UndoItemResult(
                fileName: item.fileName,
                outcome: .skipped,
                message: "Current location unknown; cannot undo"
            )
        }
        
        let currentURL = URL(fileURLWithPath: currentPath)
        
        // Check current state
        let originalExists = fileManager.fileExists(atPath: originalURL.path)
        let currentExists = fileManager.fileExists(atPath: currentURL.path)
        
        // Case 1: Both exist (was a copy) - trash the copy
        if originalExists && currentExists && item.actionType == .copied {
            do {
                var trashURL: NSURL?
                try fileManager.trashItem(at: currentURL, resultingItemURL: &trashURL)
                return UndoItemResult(
                    fileName: item.fileName,
                    outcome: .restored,
                    message: "Moved copied file to Trash"
                )
            } catch {
                return UndoItemResult(
                    fileName: item.fileName,
                    outcome: .failed,
                    message: "Failed to remove copy: \(error.localizedDescription)"
                )
            }
        }
        
        // Case 2: Only current exists (was a move) - move back to original
        if !originalExists && currentExists {
            do {
                // Create parent directory if needed
                let parentDir = originalURL.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: parentDir.path) {
                    try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
                }
                
                try fileManager.moveItem(at: currentURL, to: originalURL)
                return UndoItemResult(
                    fileName: item.fileName,
                    outcome: .restored,
                    message: "Restored to original location"
                )
            } catch {
                return UndoItemResult(
                    fileName: item.fileName,
                    outcome: .failed,
                    message: "Failed to move back: \(error.localizedDescription)"
                )
            }
        }
        
        // Case 3: Original already exists - already undone or conflict
        if originalExists && !currentExists {
            return UndoItemResult(
                fileName: item.fileName,
                outcome: .skipped,
                message: "File already at original location"
            )
        }
        
        // Case 4: Neither exists - file is lost
        return UndoItemResult(
            fileName: item.fileName,
            outcome: .skipped,
            message: "File not found at either location; cannot undo"
        )
    }
    
    private func undoDelete(item: HistoryItem, originalURL: URL) -> UndoItemResult {
        guard let trashPath = item.currentPath else {
            return UndoItemResult(
                fileName: item.fileName,
                outcome: .skipped,
                message: "Trash location unknown; cannot restore"
            )
        }
        
        let trashURL = URL(fileURLWithPath: trashPath)
        
        // Check if file still in trash
        guard fileManager.fileExists(atPath: trashURL.path) else {
            return UndoItemResult(
                fileName: item.fileName,
                outcome: .skipped,
                message: "File no longer in Trash (may have been emptied)"
            )
        }
        
        // Check if original location is free
        if fileManager.fileExists(atPath: originalURL.path) {
            return UndoItemResult(
                fileName: item.fileName,
                outcome: .skipped,
                message: "Original location is occupied; cannot restore"
            )
        }
        
        // Restore from trash
        do {
            // Create parent directory if needed
            let parentDir = originalURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parentDir.path) {
                try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            
            try fileManager.moveItem(at: trashURL, to: originalURL)
            return UndoItemResult(
                fileName: item.fileName,
                outcome: .restored,
                message: "Restored from Trash"
            )
        } catch {
            return UndoItemResult(
                fileName: item.fileName,
                outcome: .failed,
                message: "Failed to restore: \(error.localizedDescription)"
            )
        }
    }
    
    // MARK: - Private Methods
    
    private func determineActionType(from entry: ExecutionLog.Entry) -> HistoryActionType {
        // Determine based on destination and message
        if entry.outcome == .skipped {
            return .skipped
        }
        
        if let message = entry.message?.lowercased() {
            if message.contains("trash") {
                return .deleted
            }
        }
        
        if entry.destinationURL != nil {
            if entry.sourceURL.deletingLastPathComponent() == entry.destinationURL?.deletingLastPathComponent() {
                return .renamed
            }
            return .moved
        }
        
        return .moved
    }
    
    private func mapOutcome(_ outcome: ExecutionLog.Entry.Outcome) -> HistoryOutcome {
        switch outcome {
        case .success: return .success
        case .failed: return .failed
        case .skipped: return .skipped
        }
    }
    
    private var historyFileURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("FileScannerApp", isDirectory: true)
        
        // Create directory if needed
        if !fileManager.fileExists(atPath: appFolder.path) {
            try? fileManager.createDirectory(at: appFolder, withIntermediateDirectories: true)
        }
        
        return appFolder.appendingPathComponent(historyFileName)
    }
    
    private func loadHistory() {
        guard fileManager.fileExists(atPath: historyFileURL.path) else {
            sessions = []
            return
        }
        
        do {
            let data = try Data(contentsOf: historyFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            sessions = try decoder.decode([HistorySession].self, from: data)
        } catch {
            print("Failed to load history: \(error)")
            sessions = []
        }
    }
    
    private func saveHistory() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(sessions)
            try data.write(to: historyFileURL, options: .atomic)
        } catch {
            print("Failed to save history: \(error)")
        }
    }
}

// MARK: - Date Formatting Helpers

extension HistoryItem {
    /// Formatted date string for display
    public var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: timestamp)
    }
    
    /// Formatted time string for display
    public var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
    
    /// Formatted date and time for display
    public var formattedDateTime: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
}

extension HistorySession {
    /// Formatted date string for display
    public var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: timestamp)
    }
    
    /// Formatted time string for display
    public var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
    
    /// Relative time description (e.g., "2 hours ago")
    public var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: timestamp, relativeTo: Date())
    }
}
