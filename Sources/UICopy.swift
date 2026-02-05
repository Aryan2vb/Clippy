import Foundation

/// Central repository for all user-facing strings.
/// Separating copy allows for consistent tone, easier review, and potential localization.
enum UICopy {
    
    // MARK: - Sidebar & Navigation
    enum Sidebar {
        static let organize = "Organize"
        static let rules = "Rules"
        static let history = "History"
        static let selectFolder = "Select Folder"
        static let changeFolder = "Change Folder"
    }
    
    // MARK: - Headers & Status
    enum Header {
        static let organizeTitle = "Organize"
        static let scanUpToDate = "Scan is up to date"
        static let scanMayBeStale = "Scan may be out of date"
        static let scanRecommended = "Scan recommended"
        static let noScanYet = "Select a folder to begin"
        
        static func filesAnalyzed(_ count: Int) -> String {
            "\(count) files analyzed"
        }
        
        static func activeRules(_ count: Int) -> String {
            "\(count) active rules"
        }
        
        static func lastScanned(_ timeAgo: String) -> String {
            "Last scanned \(timeAgo)"
        }
    }
    
    // MARK: - Empty States
    enum EmptyState {
        static let noFolderTitle = "No folder selected"
        static let noFolderBody = "Select a folder from the sidebar to begin organizing your files."
        static let nothingWillHappen = "Nothing will happen to your files until you approve."
        
        static let readyToScanTitle = "Ready to scan"
        static let readyToScanBody = "Scanning will analyze files and suggest changes based on your rules."
        static let startScanButton = "Review changes by scanning"
        
        static func ruleBasisHint(count: Int) -> String {
            "This plan is based on your \(count) active rules."
        }
    }
    
    // MARK: - Progress States
    enum Progress {
        static let scanningTitle = "Scanning folder..."
        static let scanningBody = "This may take a moment for large folders."
        
        static let executingTitle = "Applying changes..."
        static let executingBody = "Each action is logged for your review."
    }
    
    // MARK: - Plan Preview
    enum Plan {
        static let title = "Proposed changes"
        static let reassurance = "Nothing will happen until you approve."
        static let approveButton = "Approve and apply changes"
        static let cancelButton = "Cancel"
        static let createPlanButton = "Create Plan"
        static let confidenceHint = "This plan is based on the most recent scan."
        
        static func summaryMoved(_ count: Int) -> String {
            "\(count) would be moved"
        }
        static func summaryTrash(_ count: Int) -> String {
            "\(count) would go to Trash"
        }
        static func summarySkipped(_ count: Int) -> String {
            "\(count) skipped"
        }
        
        static func reason(_ text: String) -> String {
            "Because \(text.lowercased())"
        }
    }
    
    // MARK: - Execution Results
    enum Execution {
        static let title = "What happened"
        static let undoButton = "Undo recent changes"
        static let doneButton = "Done"
        
        static let partialFailure = "Some changes could not be completed. Details are shown below."
        static func successSummary(_ count: Int) -> String {
            "\(count) changes have been applied."
        }
        
        static func movedTo(_ dest: String) -> String {
            "Moved to \(dest)"
        }
        static let completed = "Completed"
        
        static func skipped(_ reason: String) -> String {
            "Skipped because \(reason.lowercased())"
        }
        static func failed(_ reason: String) -> String {
            "Could not be completed because \(reason.lowercased())"
        }
    }
    
    // MARK: - Rules
    enum Rules {
        static let title = "Rules"
        static let subtitle = "Define how your files should be organized"
        static let addButton = "Add Rule"
        static let editButton = "Edit"
        static let saveButton = "Save Rule"
        static let cancelButton = "Cancel"
        static let disabled = "Disabled"
        
        static let emptyTitle = "No rules yet"
        static let emptyBody = "Rules define how files are organized.\nAdd your first rule to get started."
        
        static let editorAddTitle = "Add Rule"
        static let editorEditTitle = "Edit Rule"
        
        static let sectionDetails = "Rule Details"
        static let sectionConditions = "When a file..."
        static let sectionOutcomes = "Then..."
        
        static let namePlaceholder = "e.g., Archive PDFs"
        static let descPlaceholder = "e.g., Move old PDF files to archive"
        
        static let conditionExtension = "File Extension"
        static let conditionName = "File Name Contains"
        static let conditionSize = "File Size Larger Than"
        
        static let actionMove = "Move to Folder"
        static let actionDelete = "Move to Trash"
    }
    
    // MARK: - History
    enum History {
        static let title = "History"
        static let subtitle = "View all past file operations with dates, times, and current locations"
        
        static let emptyTitle = "No history yet"
        static let emptyBody = "Actions you perform will appear here.\nYou'll see what happened, when, and where files are now."
        
        static let clearAllButton = "Clear All"
        static let clearConfirmTitle = "Clear History?"
        static let clearConfirmMessage = "This will remove all history records. This action cannot be undone."
        static let clearConfirmButton = "Clear"
        static let cancelButton = "Cancel"
        
        static let sessionHeader = "Session"
        static let filesProcessed = "files processed"
        
        static let originalLocation = "Original"
        static let currentLocation = "Current"
        static let fileNotFound = "File no longer exists"
        static let revealInFinder = "Reveal in Finder"
        
        static func sessionSummary(success: Int, failed: Int, skipped: Int) -> String {
            var parts: [String] = []
            if success > 0 { parts.append("\(success) succeeded") }
            if failed > 0 { parts.append("\(failed) failed") }
            if skipped > 0 { parts.append("\(skipped) skipped") }
            return parts.joined(separator: ", ")
        }
        
        static func actionAt(time: String) -> String {
            "at \(time)"
        }
        
        static let deleteSession = "Delete Session"
        
        // Undo
        static let undoSessionButton = "Undo All"
        static let undoItemButton = "Undo"
        static let undoConfirmTitle = "Undo Changes?"
        static let undoConfirmMessage = "This will restore all files to their original locations. Files that were moved will be moved back, and copies will be removed."
        static let undoConfirmButton = "Undo Changes"
        
        static let undoResultTitle = "Undo Complete"
        static let undoSuccessMessage = "All files have been restored to their original locations."
        static let undoPartialMessage = "Some files could not be restored. See details below."
        
        static func undoResultSummary(restored: Int, skipped: Int, failed: Int) -> String {
            var parts: [String] = []
            if restored > 0 { parts.append("\(restored) restored") }
            if skipped > 0 { parts.append("\(skipped) skipped") }
            if failed > 0 { parts.append("\(failed) failed") }
            return parts.joined(separator: ", ")
        }
        
        static let undoRestored = "Restored"
        static let undoSkipped = "Skipped"
        static let undoFailed = "Failed"
        static let okButton = "OK"
    }
    
    // MARK: - Common
    enum Common {
        static func andMore(_ count: Int) -> String {
            "... and \(count) more files"
        }
        static let unknownReason = "reason unknown"
        
        static func conditionExt(_ ext: String) -> String { ".\(ext)" }
        static func conditionContains(_ text: String) -> String { "contains \"\(text)\"" }
        static func conditionSize(_ size: String) -> String { "> \(size)" }
        static func conditionDate(_ date: String) -> String { "before \(date)" }
        static let conditionFolder = "is folder"
        
        static func outcomeRename(_ p: String?, _ s: String?) -> String {
            var text = "Rename"
            if let p = p { text += " +\(p)" }
            if let s = s { text += " +\(s)" }
            return text
        }
    }
}
