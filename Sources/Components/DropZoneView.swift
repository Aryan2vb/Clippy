import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drop Zone View

/// A large dashed-border drop target for folder selection.
/// Accepts folder drops via drag-and-drop and provides a fallback "Choose Folder" button.
///
/// Displays:
/// - A dashed RoundedRectangle drop zone
/// - Folder icon and instructional text
/// - Visual feedback when a drag enters the zone
/// - The selected folder path once chosen
struct DropZoneView: View {
    @Binding var selectedFolderURL: URL?
    let onFolderSelected: (URL) -> Void
    
    @State private var isDropTargeted = false
    @State private var showFileImporter = false
    @State private var dropErrorMessage: String?
    
    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xxl) {
            if let url = selectedFolderURL {
                selectedFolderDisplay(url)
            } else {
                dropZoneContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                selectedFolderURL = url
                onFolderSelected(url)
            }
        }
    }
    
    // MARK: - Drop Zone Content
    
    private var dropZoneContent: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            // Drop zone
            VStack(spacing: DesignSystem.Spacing.lg) {
                Image(systemName: isDropTargeted ? "folder.fill.badge.plus" : "folder.badge.plus")
                    .font(.system(size: 56))
                    .foregroundColor(isDropTargeted ? .accentColor : .secondary.opacity(0.6))
                    .animation(.easeInOut(duration: 0.2), value: isDropTargeted)
                
                VStack(spacing: DesignSystem.Spacing.xs) {
                    Text("Drop a folder here")
                        .font(DesignSystem.Typography.title3)
                        .foregroundColor(isDropTargeted ? .accentColor : .primary)
                    
                    Text("or use the button below to choose one")
                        .font(DesignSystem.Typography.body)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: 400, minHeight: 200)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.lg)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                        style: StrokeStyle(lineWidth: 2.5, dash: [10, 6])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.lg)
                            .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                    )
            )
            .scaleEffect(isDropTargeted ? 1.03 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isDropTargeted)
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
                return true
            }
            
            // Fallback button
            Button {
                showFileImporter = true
            } label: {
                Label("Choose Folder", systemImage: "folder")
                    .padding(.horizontal, DesignSystem.Spacing.sm)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            
            // Trust hint with icon
            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.caption)
                    .foregroundColor(.green)
                Text("Clippy will only read file names and metadata — nothing is changed until you approve.")
                    .font(DesignSystem.Typography.captionSmall)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 360)
            
            if let error = dropErrorMessage {
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    
                    // Actionable recovery hint
                    if error.contains("not a file") {
                        Text("Try dropping a folder icon from Finder")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else if error.contains("permission") {
                        Text("You may need to grant Clippy access to this folder in System Settings")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
                .transition(.opacity)
            }
        }
    }
    
    // MARK: - Selected Folder Display
    
    private func selectedFolderDisplay(_ url: URL) -> some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            Image(systemName: "folder.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)
            
            VStack(spacing: DesignSystem.Spacing.xs) {
                Text(url.lastPathComponent)
                    .font(DesignSystem.Typography.title2)
                    .foregroundColor(.primary)
                
                Text(url.path)
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 400)
            }
            
            Button {
                showFileImporter = true
            } label: {
                Label("Change Folder", systemImage: "folder.badge.gearshape")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }
    
    // MARK: - Drop Handling
    
    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                        DispatchQueue.main.async {
                            selectedFolderURL = url
                            onFolderSelected(url)
                            dropErrorMessage = nil
                        }
                    } else {
                        DispatchQueue.main.async {
                            dropErrorMessage = "That's a file, not a folder. Please drop a folder to organize its contents."
                            // Clear error after 5 seconds
                            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                                withAnimation {
                                    dropErrorMessage = nil
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
