import Foundation

// MARK: - Undo Log

/// A durable record of undo attempts.
/// Each entry corresponds to a single ExecutionLog.Entry we tried to reverse.
public struct UndoLog: Codable, Sendable {
    public let executionLogId: UUID
    public let timestamp: Date
    public var entries: [Entry]
    
    public init(executionLogId: UUID, timestamp: Date = Date(), entries: [Entry] = []) {
        self.executionLogId = executionLogId
        self.timestamp = timestamp
        self.entries = entries
    }
    
    public struct Entry: Codable, Sendable {
        public let originalActionId: UUID
        public let timestamp: Date
        public let outcome: Outcome
        public let explanation: String
        
        public init(originalActionId: UUID, timestamp: Date = Date(), outcome: Outcome, explanation: String) {
            self.originalActionId = originalActionId
            self.timestamp = timestamp
            self.outcome = outcome
            self.explanation = explanation
        }
        
        public enum Outcome: String, Codable, Sendable {
            case restored
            case skipped
            case failed
        }
    }
}

// MARK: - Undo Engine

/// Reverses previously executed actions using only persisted ExecutionLog data.
///
/// Philosophy:
/// - Undo is best-effort, not guaranteed.
/// - Missing files are facts, not errors.
/// - Undo must never worsen the user's situation.
/// - If restoration is unsafe or ambiguous, skip and explain.
public final class UndoEngine: @unchecked Sendable {
    
    private let fileManager: FileManager
    
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }
    
    /// Attempts to undo a previously executed plan.
    /// Actions are processed in reverse order to unwind correctly.
    /// - Parameter log: The ExecutionLog from a prior execution.
    /// - Returns: An UndoLog recording the outcome of each undo attempt.
    public func undo(log: ExecutionLog) -> UndoLog {
        var undoLog = UndoLog(executionLogId: log.planId)
        
        // Reverse order: last action first.
        // This handles dependencies (e.g., if A moved before B, undo B before A).
        for entry in log.entries.reversed() {
            let undoEntry = undoSingleEntry(entry)
            undoLog.entries.append(undoEntry)
        }
        
        return undoLog
    }
    
    private func undoSingleEntry(_ entry: ExecutionLog.Entry) -> UndoLog.Entry {
        // Only attempt undo on successful actions.
        // Failed or skipped actions left no trace to reverse.
        guard entry.outcome == .success else {
            return UndoLog.Entry(
                originalActionId: entry.actionId,
                outcome: .skipped,
                explanation: "Original action did not succeed; nothing to undo."
            )
        }
        
        // Determine action type by inspecting what was logged.
        // We infer the action type from the presence/absence of destinationURL
        // and the message field.
        
        if let message = entry.message, message == "Moved to Trash" {
            // This was a DELETE (trash) action
            return undoTrash(entry)
        } else if let destination = entry.destinationURL {
            // This was a MOVE, RENAME, or COPY
            // We cannot distinguish move from copy from the log alone.
            // However, the semantic difference matters:
            // - Move/Rename: destination exists, source is gone → reverse by moving back
            // - Copy: destination exists, source still exists → reverse by deleting copy
            //
            // Heuristic: If the original source still exists, it was likely a copy.
            //            If the original source is gone, it was likely a move/rename.
            return undoMoveOrCopy(entry, destination: destination)
        } else {
            // No destination, no trash message → unknown or skip action
            return UndoLog.Entry(
                originalActionId: entry.actionId,
                outcome: .skipped,
                explanation: "Action type could not be determined from log; skipping."
            )
        }
    }
    
    // MARK: - Undo Helpers
    
    /// Undo a move or rename: move the file back from destination to source.
    /// Undo a copy: delete the copied file (only if source still exists).
    private func undoMoveOrCopy(_ entry: ExecutionLog.Entry, destination: URL) -> UndoLog.Entry {
        let source = entry.sourceURL
        
        // Check current filesystem state
        let sourceExists = fileManager.fileExists(atPath: source.path)
        let destinationExists = fileManager.fileExists(atPath: destination.path)
        
        // Case 1: Source exists AND destination exists → likely a COPY
        // Undo by trashing the copy (destination).
        if sourceExists && destinationExists {
            var trashURL: NSURL?
            do {
                try fileManager.trashItem(at: destination, resultingItemURL: &trashURL)
                return UndoLog.Entry(
                    originalActionId: entry.actionId,
                    outcome: .restored,
                    explanation: "Moved copied file to Trash."
                )
            } catch {
                return UndoLog.Entry(
                    originalActionId: entry.actionId,
                    outcome: .failed,
                    explanation: "Failed to trash copied file: \(error.localizedDescription)"
                )
            }
        }
        
        // Case 2: Source is gone, destination exists → likely a MOVE/RENAME
        // Undo by moving destination back to source.
        if !sourceExists && destinationExists {
            do {
                try fileManager.moveItem(at: destination, to: source)
                return UndoLog.Entry(
                    originalActionId: entry.actionId,
                    outcome: .restored,
                    explanation: "Moved file back to original location."
                )
            } catch {
                return UndoLog.Entry(
                    originalActionId: entry.actionId,
                    outcome: .failed,
                    explanation: "Failed to move file back: \(error.localizedDescription)"
                )
            }
        }
        
        // Case 3: Source exists, destination is gone → already undone or user intervened
        if sourceExists && !destinationExists {
            return UndoLog.Entry(
                originalActionId: entry.actionId,
                outcome: .skipped,
                explanation: "File already at original location; destination no longer exists."
            )
        }
        
        // Case 4: Neither exists → file is lost
        return UndoLog.Entry(
            originalActionId: entry.actionId,
            outcome: .skipped,
            explanation: "Neither source nor destination exists; cannot undo."
        )
    }
    
    /// Undo a trash (delete): restore from Trash to original source.
    private func undoTrash(_ entry: ExecutionLog.Entry) -> UndoLog.Entry {
        let originalSource = entry.sourceURL
        
        guard let trashURL = entry.destinationURL else {
            // No trash URL logged → cannot restore
            return UndoLog.Entry(
                originalActionId: entry.actionId,
                outcome: .skipped,
                explanation: "Trash location was not recorded; cannot restore."
            )
        }
        
        // Check if the trashed item still exists
        guard fileManager.fileExists(atPath: trashURL.path) else {
            return UndoLog.Entry(
                originalActionId: entry.actionId,
                outcome: .skipped,
                explanation: "Trashed file no longer exists (may have been emptied)."
            )
        }
        
        // Check if original location is free
        if fileManager.fileExists(atPath: originalSource.path) {
            // Original path is occupied.
            // Option: restore to a safe alternative location.
            // For now, we skip to avoid overwriting.
            // A more advanced implementation could rename to "filename (restored).ext".
            return UndoLog.Entry(
                originalActionId: entry.actionId,
                outcome: .skipped,
                explanation: "Original location is now occupied; skipping to avoid overwrite."
            )
        }
        
        // Attempt to restore
        do {
            try fileManager.moveItem(at: trashURL, to: originalSource)
            return UndoLog.Entry(
                originalActionId: entry.actionId,
                outcome: .restored,
                explanation: "Restored from Trash to original location."
            )
        } catch {
            return UndoLog.Entry(
                originalActionId: entry.actionId,
                outcome: .failed,
                explanation: "Failed to restore from Trash: \(error.localizedDescription)"
            )
        }
    }
}

// MARK: - Example Usage

public func undoExample() {
    print("--- Undo Engine Example ---")
    
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory
    
    // Simulate a prior execution:
    // 1. A file was moved from /tmp/doc.txt to /tmp/Archive/doc.txt
    // 2. A file was trashed, but trash was emptied (so undo will skip)
    
    let originalSource = tempDir.appendingPathComponent("doc.txt")
    let movedDest = tempDir.appendingPathComponent("Archive/doc.txt")
    
    // Setup: Create the "moved" state (file at destination, not at source)
    try? fm.createDirectory(at: tempDir.appendingPathComponent("Archive"), withIntermediateDirectories: true)
    try? "Hello".write(to: movedDest, atomically: true, encoding: .utf8)
    try? fm.removeItem(at: originalSource) // Ensure source is gone
    
    // Create a mock ExecutionLog
    let moveEntry = ExecutionLog.Entry(
        actionId: UUID(),
        sourceURL: originalSource,
        destinationURL: movedDest,
        outcome: .success,
        message: nil
    )
    
    let trashEntry = ExecutionLog.Entry(
        actionId: UUID(),
        sourceURL: tempDir.appendingPathComponent("deleted.txt"),
        destinationURL: tempDir.appendingPathComponent(".Trash/deleted.txt"), // Fake trash path
        outcome: .success,
        message: "Moved to Trash"
    )
    
    let mockLog = ExecutionLog(
        planId: UUID(),
        entries: [moveEntry, trashEntry]
    )
    
    // Execute Undo
    let undoEngine = UndoEngine()
    let undoLog = undoEngine.undo(log: mockLog)
    
    // Print results
    print("Undo completed. Results:")
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    if let data = try? encoder.encode(undoLog), let json = String(data: data, encoding: .utf8) {
        print(json)
    }
    
    // Verify: doc.txt should be back at originalSource
    if fm.fileExists(atPath: originalSource.path) {
        print("✓ doc.txt restored to original location")
    }
    
    // Cleanup
    try? fm.removeItem(at: originalSource)
    try? fm.removeItem(at: tempDir.appendingPathComponent("Archive"))
}
