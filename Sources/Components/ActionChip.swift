import SwiftUI
import ClippyCore

// MARK: - Action Chip

/// A small pill-shaped label showing an action type with color coding.
/// Used throughout the app to consistently represent planned action types.
///
/// Color coding:
/// - Blue    → Move
/// - Green   → Copy
/// - Red     → Delete
/// - Yellow  → Rename
/// - Gray    → Skip
struct ActionChip: View {
    let actionType: ActionType
    
    var body: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: iconName)
                .font(.caption2)
            Text(label)
                .font(DesignSystem.Typography.captionSmall)
                .fontWeight(.medium)
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .background(chipColor.opacity(0.15))
        .foregroundColor(chipColor)
        .clipShape(Capsule())
    }
    
    // MARK: - Styling
    
    private var chipColor: Color {
        switch actionType {
        case .move:   return .blue
        case .copy:   return .green
        case .delete: return Color(NSColor.systemRed)
        case .rename: return .yellow
        case .skip:   return .secondary
        }
    }
    
    private var iconName: String {
        switch actionType {
        case .move:   return "arrow.right"
        case .copy:   return "doc.on.doc"
        case .delete: return "trash"
        case .rename: return "pencil"
        case .skip:   return "minus.circle"
        }
    }
    
    private var label: String {
        switch actionType {
        case .move:   return "Move"
        case .copy:   return "Copy"
        case .delete: return "Delete"
        case .rename: return "Rename"
        case .skip:   return "Skip"
        }
    }
}

// MARK: - Outcome Chip (for Rule outcomes)

/// A variant of ActionChip that works with RuleOutcome instead of ActionType.
struct OutcomeChipView: View {
    let outcome: RuleOutcome
    
    var body: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: iconName)
                .font(.caption2)
            Text(label)
                .font(DesignSystem.Typography.captionSmall)
                .fontWeight(.medium)
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .background(chipColor.opacity(0.15))
        .foregroundColor(chipColor)
        .clipShape(Capsule())
    }
    
    private var chipColor: Color {
        switch outcome {
        case .move:   return .blue
        case .copy:   return .green
        case .delete: return .red
        case .rename: return .yellow
        case .skip:   return .secondary
        }
    }
    
    private var iconName: String {
        switch outcome {
        case .move:   return "arrow.right"
        case .copy:   return "doc.on.doc"
        case .delete: return "trash"
        case .rename: return "pencil"
        case .skip:   return "minus.circle"
        }
    }
    
    private var label: String {
        switch outcome {
        case .move(let url):
            return "Move → \(url.lastPathComponent)"
        case .copy(let url):
            return "Copy → \(url.lastPathComponent)"
        case .delete:
            return "Delete"
        case .rename(let prefix, let suffix):
            var text = "Rename"
            if let p = prefix { text += " +\(p)" }
            if let s = suffix { text += " +\(s)" }
            return text
        case .skip(let reason):
            return "Skip: \(reason)"
        }
    }
}
