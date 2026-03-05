import SwiftUI
import ClippyCore

// MARK: - Conflict Warning Row

/// A red-highlighted row for conflicts in the plan review screen.
/// Displayed when multiple rules match a file with different outcomes.
///
/// Shows:
/// - Red warning icon
/// - File name
/// - Explanation of the conflict
/// - The conflicting rule names
struct ConflictWarningRow: View {
    let action: PlannedAction
    
    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            // Warning icon
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.red)
            }
            
            // File info and conflict details
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Text(action.targetFile.fileName)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    // Action chip showing "Skip"
                    ActionChip(actionType: .skip)
                }
                
                // Conflict explanation
                Text(action.reason)
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(.red.opacity(0.9))
                    .lineLimit(3)
                
                // File path
                Text(action.targetFile.fileURL.deletingLastPathComponent().path)
                    .font(DesignSystem.Typography.captionSmall)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            
            Spacer()
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                .fill(Color.red.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                        .stroke(Color.red.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

// MARK: - Conflict Section Header

/// Section header for the conflicts area in the plan review.
struct ConflictSectionHeader: View {
    let count: Int
    
    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
            
            Text("Conflicts")
                .font(DesignSystem.Typography.title3)
                .fontWeight(.semibold)
                .foregroundColor(.red)
            
            Text("(\(count))")
                .font(DesignSystem.Typography.caption)
                .foregroundColor(.red.opacity(0.8))
            
            Spacer()
            
            Text("These files are skipped due to conflicting rules")
                .font(DesignSystem.Typography.captionSmall)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.sm)
    }
}
