import Foundation
import ClippyCore

/// A pure logic engine that determines actions based on files and rules.
/// Contains NO side effects, NO I/O, and NO filesystem access.
public struct Planner: Sendable {
    public init() {}

    /// Generates an ActionPlan by evaluating all files against all rules.
    /// - Parameters:
    ///   - files: The list of files found by the scanner (untrusted evidence).
    ///   - rules: The list of policies to apply.
    /// - Returns: An immutable ActionPlan containing a PlannedAction for every file.
    public func plan(files: [FileDescriptor], rules: [Rule]) -> ActionPlan {
        var actions: [PlannedAction] = []
        
        for file in files {
            // 1. Evaluate all rules against this file
            let matches = evaluate(file: file, against: rules)
            
            // 2. Resolve any conflicts or ambiguities
            let action = resolve(file: file, matches: matches)
            
            actions.append(action)
        }
        
        return ActionPlan(actions: actions)
    }

    // MARK: - internal evaluation logic

    /// A helper struct to track which rule matched and produced which outcome.
    struct RuleMatch {
        let rule: Rule
        let outcome: RuleOutcome
    }
    
    /// Finds all rules that apply to a given file.
    private func evaluate(file: FileDescriptor, against rules: [Rule]) -> [RuleMatch] {
        var matches: [RuleMatch] = []
        
        for rule in rules where rule.isEnabled {
            if matchesCondition(file: file, conditions: rule.conditions) {
                matches.append(RuleMatch(rule: rule, outcome: rule.outcome))
            }
        }
        
        return matches
    }
    
    /// Checks if a file satisfies ALL conditions in a list.
    private func matchesCondition(file: FileDescriptor, conditions: [RuleCondition]) -> Bool {
        for condition in conditions {
            switch condition {
            case .fileExtension(let ext):
                // Case-insensitive comparison for extensions
                if file.fileExtension.caseInsensitiveCompare(ext) != .orderedSame {
                    return false
                }
            case .fileName(let substring):
                if !file.fileName.localizedCaseInsensitiveContains(substring) {
                    return false
                }
            case .fileNameExact(let exactName):
                if file.fileName.localizedCaseInsensitiveCompare(exactName) != .orderedSame {
                    return false
                }
            case .fileNamePrefix(let prefix):
                if !file.fileName.lowercased().hasPrefix(prefix.lowercased()) {
                    return false
                }
            case .fileSize(let limit):
                guard let size = file.fileSize else { return false } // Missing metadata = fail condition
                if size <= limit {
                    return false
                }
            case .createdBefore(let date):
                guard let created = file.createdAt else { return false }
                if created >= date {
                    return false
                }
            case .modifiedBefore(let date):
                guard let modified = file.modifiedAt else { return false }
                if modified >= date {
                    return false
                }
            case .isDirectory:
                if !file.isDirectory {
                    return false
                }
            }
        }
        return true
    }

    /// Decides the final action for a file based on rule matches.
    /// Handles conflicts conservatively (Skip over Risk).
    private func resolve(file: FileDescriptor, matches: [RuleMatch]) -> PlannedAction {
        
        // Scenario 0: No rules matched.
        if matches.isEmpty {
            return PlannedAction(
                targetFile: file,
                actionType: .skip,
                reason: "No rules matched this file."
            )
        }
        
        // Scenario 1: Exactly one rule matched.
        if matches.count == 1 {
            let match = matches[0]
            return convert(outcome: match.outcome, for: file, reason: "Matched rule: '\(match.rule.name)'")
        }
        
        // Scenario 2: Multiple rules matched. Check for conflicts.
        // We compare the *intent* (outcome). If all rules say "Delete", it's fine.
        // If one says "Delete" and another says "Move", that's a conflict.
        
        let firstOutcome = matches[0].outcome
        let allOutcomesSame = matches.allSatisfy { areOutcomesCompatible($0.outcome, firstOutcome) }
        
        if allOutcomesSame {
            // Construct a joined reason string
            let ruleNames = matches.map { "'\($0.rule.name)'" }.joined(separator: ", ")
            return convert(outcome: firstOutcome, for: file, reason: "Matched multiple rules: \(ruleNames)")
        } else {
            // CONFLICT: Different outcomes.
            // Conservative behavior: Do nothing.
            let details = matches.map { "\($0.rule.name) -> \(describe($0.outcome))" }.joined(separator: "; ")
            return PlannedAction(
                targetFile: file,
                actionType: .skip,
                reason: "Conflict! Multiple rules matched with different outcomes: [\(details)]",
                isConflict: true
            )
        }
    }
    
    // MARK: - Helpers

    /// Converts a declarative RuleOutcome to a specific ActionType
    private func convert(outcome: RuleOutcome, for file: FileDescriptor, reason: String) -> PlannedAction {
        let type: ActionType
        switch outcome {
        case .move(let folderURL):
            // Destination is folder + original filename
            let destinationURL = folderURL.appendingPathComponent(file.fileName)
            type = .move(destination: destinationURL)
        case .copy(let folderURL):
            // Destination is folder + original filename
            let destinationURL = folderURL.appendingPathComponent(file.fileName)
            type = .copy(destination: destinationURL)
        case .delete:
            type = .delete
        case .rename(let prefix, let suffix):
            // Pure logic: calculate the new name here.
            var name = file.fileName
            if let p = prefix { name = p + name }
            if let s = suffix {
                let ext = (name as NSString).pathExtension
                let base = (name as NSString).deletingPathExtension
                name = base + s + (ext.isEmpty ? "" : "." + ext)
            }
            type = .rename(newName: name)
        case .skip(let r):
            // If the rule explicitly says Skip, we combine the reasons.
            return PlannedAction(targetFile: file, actionType: .skip, reason: "\(reason). Rule Logic: \(r)")
        }
        
        return PlannedAction(targetFile: file, actionType: type, reason: reason)
    }

    /// Checks if two outcomes are logically equivalent.
    private func areOutcomesCompatible(_ a: RuleOutcome, _ b: RuleOutcome) -> Bool {
        switch (a, b) {
        case (.delete, .delete): return true
        case (.move(let u1), .move(let u2)): return u1 == u2
        case (.copy(let u1), .copy(let u2)): return u1 == u2
        case (.rename(let p1, let s1), .rename(let p2, let s2)): return p1 == p2 && s1 == s2
        case (.skip, .skip): return true
        default: return false
        }
    }
    
    private func describe(_ outcome: RuleOutcome) -> String {
        switch outcome {
        case .move(let u): return "Move to \(u.lastPathComponent)"
        case .copy(let u): return "Copy to \(u.lastPathComponent)"
        case .delete: return "Delete"
        case .rename: return "Rename"
        case .skip: return "Skip"
        }
    }
}


