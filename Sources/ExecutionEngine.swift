import Foundation

// MARK: - Execution Log

/// A durable record of what happened during execution.
/// Designed to be append-only and serializable for audit/undo.
public struct ExecutionLog: Codable, Sendable {
    public let planId: UUID
    public let timestamp: Date
    public var entries: [Entry]
    public var endTime: Date?
    
    public init(planId: UUID, timestamp: Date = Date(), entries: [Entry] = []) {
        self.planId = planId
        self.timestamp = timestamp
        self.entries = entries
    }
    
    public struct Entry: Codable, Sendable {
        public let actionId: UUID
        public let sourceURL: URL
        public let destinationURL: URL?
        public let timestamp: Date
        public let outcome: Outcome
        public let message: String?
        
        public init(actionId: UUID, sourceURL: URL, destinationURL: URL?, timestamp: Date = Date(), outcome: Outcome, message: String? = nil) {
            self.actionId = actionId
            self.sourceURL = sourceURL
            self.destinationURL = destinationURL
            self.timestamp = timestamp
            self.outcome = outcome
            self.message = message
        }
        
        public enum Outcome: String, Codable, Sendable {
            case success
            case skipped
            case failed
        }
    }
}

// MARK: - Execution Engine

/// The trusted worker that performs filesystem operations.
/// 
/// Philosophy:
/// - Obeys the ActionPlan exactly.
/// - Defensive programming: assumes the filesystem changed since planning.
/// - Failures are localized and recorded, never fatal to the whole plan.
public final class ExecutionEngine: @unchecked Sendable {
    
    private let fileManager: FileManager
    
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }
    
    /// Executes the given plan step-by-step.
    /// - Returns: A complete log of all actions taken (successes, failures, skips).
    public func execute(plan: ActionPlan) -> ExecutionLog {
        var log = ExecutionLog(planId: plan.id)
        
        for action in plan.actions {
            let entry = executeSingleAction(action)
            log.entries.append(entry)
            
            // In a production app, we would append `entry` to a file on disk here
            // to ensure durability against crashes.
        }
        
        log.endTime = Date()
        return log
    }
    
    private func executeSingleAction(_ action: PlannedAction) -> ExecutionLog.Entry {
        let source = action.targetFile.fileURL
        
        // 1. Check strict existence before doing anything
        // We verify the file is actually at the source path.
        // If it's gone, we fail (can't operate on nothing).
        guard fileManager.fileExists(atPath: source.path) else {
            return ExecutionLog.Entry(
                actionId: action.id,
                sourceURL: source,
                destinationURL: nil,
                outcome: .failed,
                message: "Source file not found at path"
            )
        }
        
        // Dispatch based on action type
        switch action.actionType {
        case .move(let destination):
            return performMove(action: action, to: destination)
            
        case .copy(let destination):
            return performCopy(action: action, to: destination)
            
        case .delete:
            return performDelete(action: action)
            
        case .rename(let newName):
            return performRename(action: action, newName: newName)
            
        case .skip:
            return ExecutionLog.Entry(
                actionId: action.id,
                sourceURL: source,
                destinationURL: nil,
                outcome: .skipped,
                message: "Plan explicitly skipped this action"
            )
        }
    }
    
    // MARK: - Safe Operations
    
    private func performMove(action: PlannedAction, to destination: URL) -> ExecutionLog.Entry {
        // Safety: Do not overwrite
        if fileManager.fileExists(atPath: destination.path) {
            return ExecutionLog.Entry(
                actionId: action.id,
                sourceURL: action.targetFile.fileURL,
                destinationURL: destination,
                outcome: .failed,
                message: "Destination already exists"
            )
        }
        
        do {
            // Create parent directory if needed.
            // The plan specifies WHERE to move; if the folder doesn't exist,
            // creating it is a reasonable interpretation of user intent.
            let parentDir = destination.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parentDir.path) {
                try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            
            try fileManager.moveItem(at: action.targetFile.fileURL, to: destination)
            return ExecutionLog.Entry(
                actionId: action.id,
                sourceURL: action.targetFile.fileURL,
                destinationURL: destination,
                outcome: .success
            )
        } catch {
            return ExecutionLog.Entry(
                actionId: action.id,
                sourceURL: action.targetFile.fileURL,
                destinationURL: destination,
                outcome: .failed,
                message: error.localizedDescription
            )
        }
    }
    
    private func performCopy(action: PlannedAction, to destination: URL) -> ExecutionLog.Entry {
        if fileManager.fileExists(atPath: destination.path) {
            return ExecutionLog.Entry(
                actionId: action.id,
                sourceURL: action.targetFile.fileURL,
                destinationURL: destination,
                outcome: .failed,
                message: "Destination already exists"
            )
        }
        
        do {
            // Create parent directory if needed
            let parentDir = destination.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parentDir.path) {
                try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            
            try fileManager.copyItem(at: action.targetFile.fileURL, to: destination)
            return ExecutionLog.Entry(
                actionId: action.id,
                sourceURL: action.targetFile.fileURL,
                destinationURL: destination,
                outcome: .success
            )
        } catch {
            return ExecutionLog.Entry(
                actionId: action.id,
                sourceURL: action.targetFile.fileURL,
                destinationURL: destination,
                outcome: .failed,
                message: error.localizedDescription
            )
        }
    }
    
    /// Performs a reversible delete by moving the file to the system Trash.
    ///
    /// Semantic contract:
    /// - "delete" in this engine means "move to Trash" (reversible).
    /// - Permanent deletion (removeItem) is explicitly out of scope.
    /// - The resulting trash URL is logged to support future undo.
    private func performDelete(action: PlannedAction) -> ExecutionLog.Entry {
        var trashURL: NSURL?
        do {
            // Use trashItem to move the file to Trash.
            // This is reversible—the user (or a future undo system) can restore it.
            // Permanent deletion is NOT supported by this engine.
            try fileManager.trashItem(at: action.targetFile.fileURL, resultingItemURL: &trashURL)
            
            return ExecutionLog.Entry(
                actionId: action.id,
                sourceURL: action.targetFile.fileURL,
                destinationURL: trashURL as URL?,  // Where the file now lives in Trash
                outcome: .success,
                message: "Moved to Trash"
            )
        } catch {
            return ExecutionLog.Entry(
                actionId: action.id,
                sourceURL: action.targetFile.fileURL,
                destinationURL: nil,
                outcome: .failed,
                message: error.localizedDescription
            )
        }
    }
    
    private func performRename(action: PlannedAction, newName: String) -> ExecutionLog.Entry {
        let source = action.targetFile.fileURL
        let directory = source.deletingLastPathComponent()
        let destination = directory.appendingPathComponent(newName)
        
        // Safety: Renaming to same name is a no-op success or skip?
        if source == destination {
            return ExecutionLog.Entry(
                actionId: action.id,
                sourceURL: source,
                destinationURL: destination,
                outcome: .skipped,
                message: "New name is identical to old name"
            )
        }
        
        // Safety: Check collision
        if fileManager.fileExists(atPath: destination.path) {
            return ExecutionLog.Entry(
                actionId: action.id,
                sourceURL: source,
                destinationURL: destination,
                outcome: .failed,
                message: "File with new name already exists"
            )
        }
        
        do {
            try fileManager.moveItem(at: source, to: destination)
            return ExecutionLog.Entry(
                actionId: action.id,
                sourceURL: source,
                destinationURL: destination,
                outcome: .success
            )
        } catch {
            return ExecutionLog.Entry(
                actionId: action.id,
                sourceURL: source,
                destinationURL: destination,
                outcome: .failed,
                message: error.localizedDescription
            )
        }
    }
}

// MARK: - Example Usage

public func executionExample() {
    print("--- Execution Engine Example ---")
    
    // Setup Dummy Data
    let tempDir = FileManager.default.temporaryDirectory
    let sourceFile = tempDir.appendingPathComponent("test_doc.txt")
    let destDir = tempDir.appendingPathComponent("Archive")
    let existingFile = destDir.appendingPathComponent("existing.txt")
    
    // Create dummy files for the test
    try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
    try? "Hello World".write(to: sourceFile, atomically: true, encoding: .utf8)
    try? "I exist".write(to: existingFile, atomically: true, encoding: .utf8)
    
    // 1. Define Actions
    
    // Action A: Move test_doc.txt -> Archive/test_doc.txt (Should SUCCEED)
    let fileA = FileDescriptor(
        fileURL: sourceFile,
        fileName: "test_doc.txt",
        fileExtension: "txt",
        fileSize: 11,
        createdAt: Date(),
        modifiedAt: Date(),
        isDirectory: false,
        isSymlink: false,
        permissionsReadable: true
    )
    
    let actionA = PlannedAction(
        targetFile: fileA,
        actionType: .move(destination: destDir.appendingPathComponent("test_doc.txt")),
        reason: "Archive text files"
    )
    
    // Action B: Move missing.txt -> Archive/missing.txt (Should FAIL - Source missing)
    let missingURL = tempDir.appendingPathComponent("missing.txt")
    let fileB = FileDescriptor(
        fileURL: missingURL,
        fileName: "missing.txt",
        fileExtension: "txt",
        fileSize: 0,
        createdAt: Date(),
        modifiedAt: Date(),
        isDirectory: false,
        isSymlink: false,
        permissionsReadable: true
    )
    
    let actionB = PlannedAction(
        targetFile: fileB,
        actionType: .move(destination: destDir.appendingPathComponent("missing.txt")),
        reason: "Move missing file"
    )
    
    // Action C: Move sourceC -> Archive/existing.txt (Should FAIL - Destination exists)
    let sourceC = tempDir.appendingPathComponent("conflict.txt")
    try? "Conflict Source".write(to: sourceC, atomically: true, encoding: .utf8)
    
    let fileC = FileDescriptor(
        fileURL: sourceC,
        fileName: "conflict.txt",
        fileExtension: "txt",
        fileSize: 11,
        createdAt: Date(),
        modifiedAt: Date(),
        isDirectory: false,
        isSymlink: false,
        permissionsReadable: true
    )
    
    let actionC = PlannedAction(
        targetFile: fileC,
        actionType: .move(destination: existingFile),
        reason: "Conflict test"
    )
    
    // 2. Create Plan
    let plan = ActionPlan(actions: [actionA, actionB, actionC])
    
    // 3. Execute
    let engine = ExecutionEngine()
    let log = engine.execute(plan: plan)
    
    // 4. Inspect Log
    print("Execution completed. Log entries:")
    
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    if let data = try? encoder.encode(log), let json = String(data: data, encoding: .utf8) {
        print(json)
    }
    
    // Cleanup
    try? FileManager.default.removeItem(at: sourceC)
    try? FileManager.default.removeItem(at: destDir.appendingPathComponent("test_doc.txt"))
    // sourceFile is already moved
    try? FileManager.default.removeItem(at: existingFile)
    try? FileManager.default.removeItem(at: destDir)
}
