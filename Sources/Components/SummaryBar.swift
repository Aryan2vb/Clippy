import SwiftUI
import ClippyCore

// MARK: - Summary Bar

/// Bottom bar summarizing planned action counts for the Action Plan review screen.
/// Shows counts for each action type and highlights conflicts.
///
/// Example: "12 moves · 3 renames · 2 skips · 1 conflict"
struct SummaryBar: View {
    let plan: ActionPlan
    let conflictCount: Int
    
    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            // Action counts
            HStack(spacing: DesignSystem.Spacing.sm) {
                ForEach(summaryItems, id: \.label) { item in
                    if item.count > 0 {
                        SummaryItem(
                            count: item.count,
                            label: item.label,
                            color: item.color,
                            icon: item.icon
                        )
                        
                        if item.label != summaryItems.last(where: { $0.count > 0 })?.label {
                            Text("·")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                }
            }
            
            Spacer()
            
            // Conflict indicator
            if conflictCount > 0 {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                    Text("\(conflictCount) conflict\(conflictCount == 1 ? "" : "s")")
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.red)
                }
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, DesignSystem.Spacing.xs)
                .background(Color.red.opacity(0.1))
                .cornerRadius(DesignSystem.CornerRadius.sm)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.md)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    // MARK: - Computed Summary
    
    private struct SummaryItemData: Equatable {
        let count: Int
        let label: String
        let color: Color
        let icon: String
    }
    
    private var summaryItems: [SummaryItemData] {
        [
            SummaryItemData(
                count: plan.actions.filter { if case .move = $0.actionType { return true }; return false }.count,
                label: "moves",
                color: .blue,
                icon: "arrow.right"
            ),
            SummaryItemData(
                count: plan.actions.filter { if case .copy = $0.actionType { return true }; return false }.count,
                label: "copies",
                color: .green,
                icon: "doc.on.doc"
            ),
            SummaryItemData(
                count: plan.actions.filter { if case .delete = $0.actionType { return true }; return false }.count,
                label: "deletes",
                color: .red,
                icon: "trash"
            ),
            SummaryItemData(
                count: plan.actions.filter { if case .rename = $0.actionType { return true }; return false }.count,
                label: "renames",
                color: .yellow,
                icon: "pencil"
            ),
            SummaryItemData(
                count: plan.actions.filter { if case .skip = $0.actionType { return true }; return false }.count,
                label: "skips",
                color: .secondary,
                icon: "minus.circle"
            )
        ]
    }
}

// MARK: - Summary Item

/// Individual count item within the summary bar.
private struct SummaryItem: View {
    let count: Int
    let label: String
    let color: Color
    let icon: String
    
    var body: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundColor(color)
            
            Text("\(count)")
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .monospacedDigit()
            
            Text(label)
                .font(DesignSystem.Typography.captionSmall)
                .foregroundColor(.secondary)
        }
    }
}
