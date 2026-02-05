import Foundation

// MARK: - Rules

/// A declarative rule that defines a condition and a desired outcome.
/// Rules express intent ("Move old PDFs") without containing execution logic.
public struct Rule: Identifiable, Sendable, Codable {
    public let id: UUID
    public let name: String
    public let description: String
    public let conditions: [RuleCondition]
    public let outcome: RuleOutcome
    public let isEnabled: Bool
    
    public init(id: UUID = UUID(), name: String, description: String, conditions: [RuleCondition], outcome: RuleOutcome, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.description = description
        self.conditions = conditions
        self.outcome = outcome
        self.isEnabled = isEnabled
    }
}

/// Logical conditions that can be checked against a FileDescriptor.
/// These are declarative descriptions of "what to match".
public enum RuleCondition: Sendable, Codable {
    case fileExtension(is: String)
    case fileName(contains: String)
    case fileSize(largerThan: Int64)
    case createdBefore(date: Date)
    case modifiedBefore(date: Date)
    case isDirectory
    
    // Future expansion: regex, permissions, tags, etc.
}

/// The desired intent if a rule matches.
/// Does NOT perform the action; merely describes it.
public enum RuleOutcome: Sendable, Codable {
    case move(to: URL)
    case copy(to: URL)
    case delete
    case rename(prefix: String?, suffix: String?)
    case skip(reason: String) // Explicitly decide to do nothing
}

// MARK: - Planning

/// A specific intent to perform an action on a specific file.
/// Connects a FileDescriptor (evidence) to a RuleOutcome (intent).
public struct PlannedAction: Identifiable, Sendable {
    public let id: UUID
    public let targetFile: FileDescriptor
    public let actionType: ActionType
    public let reason: String // Human-readable explanation (e.g., "Matched rule 'Archive PDFs'")
    
    public init(targetFile: FileDescriptor, actionType: ActionType, reason: String) {
        self.id = UUID()
        self.targetFile = targetFile
        self.actionType = actionType
        self.reason = reason
    }
}

/// Detailed type of action to be performed.
/// Similar to RuleOutcome but specific to a single file instance.
public enum ActionType: Sendable {
    case move(destination: URL)
    case copy(destination: URL)
    case delete
    case rename(newName: String)
    case skip
}

/// An immutable collection of planned actions.
/// Represents a "transaction" of intent that the user can review before execution.
public struct ActionPlan: Sendable {
    public let id: UUID
    public let actions: [PlannedAction]
    public let createdAt: Date
    
    public init(actions: [PlannedAction]) {
        self.id = UUID()
        self.actions = actions
        self.createdAt = Date()
    }
    
    public var totalActions: Int { actions.count }
    public var summary: String {
        "Plan created at \(createdAt) with \(totalActions) pending actions."
    }
    
    /// A human-readable summary designed to reassure non-technical users.
    public var userFriendlySummary: String {
        let moveCount = actions.filter { if case .move = $0.actionType { return true }; return false }.count
        let deleteCount = actions.filter { if case .delete = $0.actionType { return true }; return false }.count
        let skipCount = actions.filter { if case .skip = $0.actionType { return true }; return false }.count
        
        var lines = ["I've analyzed your files and found \(totalActions) total items."]
        
        if moveCount > 0 { lines.append("• \(moveCount) will be moved to new locations.") }
        if deleteCount > 0 { lines.append("• \(deleteCount) will be permanently deleted.") }
        if skipCount > 0 { lines.append("• \(skipCount) will be skipped (no action needed or conflict detected).") }
        
        lines.append("\nNothing will happen to your files until you click 'Confirm'.")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Example Usage (Commented)
public func exampleUsage() {
    // 1. Evidence (from Scanner)
    let file = FileDescriptor(
        fileURL: URL(fileURLWithPath: "/Users/aryansoni/Downloads/8343073283.pdf"),
        fileName: "8343073283.pdf",
        fileExtension: "pdf",
        fileSize: 1024,
        createdAt: Date(),
        modifiedAt: Date(),
        isDirectory: false,
        isSymlink: false,
        permissionsReadable: true
    )
    
    // 2. Rule (Policy)
    let archivePDFsRule = Rule(
        name: "Archive PDFs",
        description: "Move all PDF files to the Archive folder",
        conditions: [.fileExtension(is: "pdf")],
        outcome: .move(to: URL(fileURLWithPath: "/Users/me/Documents/Archive"))
    )
    
    // 3. Planning (Logic - would happen in a Planner engine)
    // Hypothetical match logic:
    let planAction = PlannedAction(
        targetFile: file,
        actionType: .move(destination: URL(fileURLWithPath: "/Users/me/Documents/Archive")),
        reason: "Matched rule: \(archivePDFsRule.name)"
    )
    
    let plan = ActionPlan(actions: [planAction])
    print(plan.summary)
}
