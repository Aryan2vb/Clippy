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
    public let group: String?
    public let tags: [String]
    
    public init(id: UUID = UUID(), name: String, description: String, conditions: [RuleCondition], outcome: RuleOutcome, isEnabled: Bool = true, group: String? = nil, tags: [String] = []) {
        self.id = id
        self.name = name
        self.description = description
        self.conditions = conditions
        self.outcome = outcome
        self.isEnabled = isEnabled
        self.group = group
        self.tags = tags
    }
    
    /// Returns a new Rule with the given enabled state
    public func withEnabled(_ enabled: Bool) -> Rule {
        Rule(id: id, name: name, description: description, conditions: conditions,
             outcome: outcome, isEnabled: enabled, group: group, tags: tags)
    }
}

// MARK: - Rule Validation

/// Validation result for rule checking
public struct RuleValidationResult {
    public let isValid: Bool
    public let errors: [String]
    public let warnings: [String]
    
    public init(isValid: Bool, errors: [String] = [], warnings: [String] = []) {
        self.isValid = isValid
        self.errors = errors
        self.warnings = warnings
    }
}

/// Validates rules for security and correctness
public struct RuleValidator {
    /// Blocked system paths that should never be accessed
    private static let blockedPaths: [String] = [
        "/System", "/usr/bin", "/usr/sbin", "/bin", "/sbin",
        "/etc", "/var", "/private", "/private/var", "/private/etc",
        "/dev", "/Applications",
        (NSHomeDirectory() + "/Library" as NSString).standardizingPath
    ].map { ($0 as NSString).standardizingPath }
    
    /// Allowed path prefixes for user data
    private static let allowedPrefixes = [
        NSHomeDirectory(),
        "/tmp/"
    ]
    
    /// Validates a rule for security and correctness
    public static func validate(_ rule: Rule) -> RuleValidationResult {
        var errors: [String] = []
        var warnings: [String] = []
        
        // Validate name
        if rule.name.isEmpty {
            errors.append("Rule name cannot be empty")
        } else if rule.name.count > 100 {
            warnings.append("Rule name is very long (>100 characters)")
        }
        
        // Validate conditions
        if rule.conditions.isEmpty {
            errors.append("Rule must have at least one condition")
        }
        
        for condition in rule.conditions {
            switch condition {
            case .fileExtension(let ext):
                if ext.isEmpty {
                    errors.append("File extension cannot be empty")
                }
                if ext.contains("/") || ext.contains("..") {
                    errors.append("File extension contains invalid characters")
                }
            case .fileName(let name):
                if name.isEmpty {
                    errors.append("File name pattern cannot be empty")
                }
            case .fileSize(let size):
                if size < 0 {
                    errors.append("File size must be positive")
                }
                if size > 100_000_000_000 { // 100GB
                    warnings.append("File size threshold is very large (>100GB)")
                }
            default:
                break
            }
        }
        
        // Validate outcome paths
        switch rule.outcome {
        case .move(let url), .copy(let url):
            let path = sanitizePath(url.path)
            let resolvedPath = (path as NSString).standardizingPath
            
            // Check for blocked paths
            for blocked in blockedPaths {
                if resolvedPath.hasPrefix(blocked) {
                    errors.append("Destination path '\(String(resolvedPath.prefix(50)))...' is in a protected system location")
                    break
                }
            }
            
            // Check for path traversal attempts
            if path.contains("..") || path.contains("~..") {
                errors.append("Path contains directory traversal characters")
            }
            
            // Check if within allowed areas
            let isAllowed = allowedPrefixes.contains { resolvedPath.hasPrefix($0) }
            if !isAllowed && !path.hasPrefix("/tmp/") {
                warnings.append("Destination path is outside standard user directories")
            }
            
        default:
            break
        }
        
        return RuleValidationResult(isValid: errors.isEmpty, errors: errors, warnings: warnings)
    }
    
    /// Sanitizes a path string to prevent traversal attacks
    public static func sanitizePath(_ path: String) -> String {
        var result = path.trimmingCharacters(in: .whitespaces)
        // Remove null bytes
        result = result.replacingOccurrences(of: "\0", with: "")
        // Expand ~ if present
        if result.hasPrefix("~") {
            result = (result as NSString).expandingTildeInPath
        }
        // Use standardizingPath to safely resolve ../ and normalize
        result = (result as NSString).standardizingPath
        return result
    }
}

/// Logical conditions that can be checked against a FileDescriptor.
/// These are declarative descriptions of "what to match".
public enum RuleCondition: Sendable, Codable {
    case fileExtension(is: String)
    case fileName(contains: String)
    case fileNameExact(is: String)
    case fileNamePrefix(startsWith: String)
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
    public let isConflict: Bool
    
    public init(targetFile: FileDescriptor, actionType: ActionType, reason: String, isConflict: Bool = false) {
        self.id = UUID()
        self.targetFile = targetFile
        self.actionType = actionType
        self.reason = reason
        self.isConflict = isConflict
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
        if deleteCount > 0 { lines.append("• \(deleteCount) will be moved to Trash.") }
        if skipCount > 0 { lines.append("• \(skipCount) will be skipped (no action needed or conflict detected).") }
        
        lines.append("\nNothing will happen to your files until you click 'Confirm'.")
        return lines.joined(separator: "\n")
    }
}

// MARK: - LLM Suggestion Models

public struct FolderTreeSummary: Codable, Sendable {
    public let rootPath: String
    public let totalFiles: Int
    public let totalSizeBytes: Int64
    public let topLevelItems: [FolderTreeItem]
    
    public init(rootPath: String, totalFiles: Int, totalSizeBytes: Int64, topLevelItems: [FolderTreeItem]) {
        self.rootPath = rootPath
        self.totalFiles = totalFiles
        self.totalSizeBytes = totalSizeBytes
        self.topLevelItems = topLevelItems
    }
}

public struct FolderTreeItem: Codable, Sendable {
    public let name: String
    public let isDirectory: Bool
    public let sizeBytes: Int64
    public let fileCount: Int
    public let `extension`: String?
    public let modifiedDaysAgo: Int
    
    public init(name: String, isDirectory: Bool, sizeBytes: Int64, fileCount: Int, extension: String? = nil, modifiedDaysAgo: Int) {
        self.name = name
        self.isDirectory = isDirectory
        self.sizeBytes = sizeBytes
        self.fileCount = fileCount
        self.extension = `extension`
        self.modifiedDaysAgo = modifiedDaysAgo
    }
}

public struct LLMSuggestion: Identifiable, Codable, Sendable {
    public let id: UUID
    public let type: SuggestionType
    public let description: String
    public let affectedPaths: [String]
    public let suggestedAction: String
    public let confidence: Double
    
    public init(id: UUID = UUID(), type: SuggestionType, description: String, affectedPaths: [String], suggestedAction: String, confidence: Double) {
        self.id = id
        self.type = type
        self.description = description
        self.affectedPaths = affectedPaths
        self.suggestedAction = suggestedAction
        self.confidence = confidence
    }
}

public enum SuggestionType: String, Codable, Sendable {
    case groupOrphanFiles
    case potentialVersions
    case oldUnusedFiles
    case misplacedFiles
    case largeFilesReview
}
