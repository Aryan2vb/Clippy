import SwiftUI
import QuickLookThumbnailing
import QuickLookUI
import AppKit

// MARK: - QuickLook Preview Item Wrapper

/// A class wrapper for URL that conforms to QLPreviewItem
/// QLPreviewItem requires NSObjectProtocol, so we need a class (not a struct like URL)
final class PreviewItem: NSObject, QLPreviewItem {
    let url: URL
    
    init(url: URL) {
        self.url = url
        super.init()
    }
    
    var previewItemURL: URL? { url }
    var previewItemTitle: String? { url.lastPathComponent }
}

// MARK: - QuickLook Preview Controller

/// A coordinator class that manages the QuickLook preview panel
final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookCoordinator()
    
    private var currentItem: PreviewItem?
    
    private override init() {
        super.init()
    }
    
    /// Show QuickLook preview for the given file URL
    func showPreview(for url: URL) {
        currentItem = PreviewItem(url: url)
        
        guard let panel = QLPreviewPanel.shared() else { return }
        
        panel.dataSource = self
        panel.delegate = self
        
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }
    
    /// Hide the QuickLook panel
    func hidePreview() {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        panel.orderOut(nil)
    }
    
    // MARK: - QLPreviewPanelDataSource
    
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return currentItem != nil ? 1 : 0
    }
    
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        return currentItem
    }
    
    // MARK: - QLPreviewPanelDelegate
    
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown && event.keyCode == 53 { // Escape key
            hidePreview()
            return true
        }
        return false
    }
}

// MARK: - QuickLook Preview Modifier

/// A view modifier that adds QuickLook preview capability to any view
struct QuickLookPreviewModifier: ViewModifier {
    let fileURL: URL
    @Binding var isPresented: Bool
    
    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { newValue in
                if newValue {
                    QuickLookCoordinator.shared.showPreview(for: fileURL)
                    // Reset the binding after showing
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        isPresented = false
                    }
                }
            }
    }
}

extension View {
    /// Adds QuickLook preview capability to the view
    func quickLookPreview(for url: URL, isPresented: Binding<Bool>) -> some View {
        modifier(QuickLookPreviewModifier(fileURL: url, isPresented: isPresented))
    }
}

// MARK: - File Thumbnail View

/// A view that displays file thumbnails or icons based on file type.
/// Shows actual preview thumbnails for images and PDFs, system icons for other files.
/// Tap to show QuickLook preview.
struct FileThumbnailView: View {
    let file: FileDescriptor
    let size: CGFloat
    let showPreviewOnTap: Bool
    
    @State private var thumbnail: NSImage?
    @State private var isLoading = false
    @State private var showQuickLook = false
    @State private var isHovering = false
    
    init(file: FileDescriptor, size: CGFloat = 40, showPreviewOnTap: Bool = true) {
        self.file = file
        self.size = size
        self.showPreviewOnTap = showPreviewOnTap
    }
    
    var body: some View {
        ZStack {
            thumbnailContent
            
            // Quick Look overlay icon on hover
            if isHovering && showPreviewOnTap && !file.isDirectory {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.15)
                        .fill(.black.opacity(0.4))
                    
                    Image(systemName: "eye.fill")
                        .font(.system(size: size * 0.3))
                        .foregroundColor(.white)
                }
                .frame(width: size, height: size)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .onTapGesture {
            if showPreviewOnTap && !file.isDirectory {
                QuickLookCoordinator.shared.showPreview(for: file.fileURL)
            }
        }
        .help(showPreviewOnTap ? "Click to preview" : file.fileName)
        .task(id: file.fileURL) {
            await loadThumbnail()
        }
    }
    
    @ViewBuilder
    private var thumbnailContent: some View {
        if let thumbnail = thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.15))
        } else if isLoading {
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: size, height: size)
        } else {
            // Fallback to system icon
            Image(nsImage: systemIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        }
    }
    
    /// Returns the system icon for this file type
    private var systemIcon: NSImage {
        if file.isDirectory {
            return NSWorkspace.shared.icon(forFile: file.fileURL.path)
        }
        
        // Get icon for file - this returns the actual system icon for the file type
        return NSWorkspace.shared.icon(forFile: file.fileURL.path)
    }
    
    /// Check if the file type supports thumbnail preview
    private var supportsThumbnail: Bool {
        let ext = file.fileExtension.lowercased()
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp"]
        let documentExtensions = ["pdf"]
        
        return imageExtensions.contains(ext) || documentExtensions.contains(ext)
    }
    
    /// Load thumbnail asynchronously using QuickLook
    private func loadThumbnail() async {
        // Skip if it's a directory or doesn't support thumbnails
        guard !file.isDirectory, supportsThumbnail else {
            return
        }
        
        // Skip if file doesn't exist or isn't readable
        guard file.permissionsReadable,
              FileManager.default.fileExists(atPath: file.fileURL.path) else {
            return
        }
        
        isLoading = true
        
        let request = QLThumbnailGenerator.Request(
            fileAt: file.fileURL,
            size: CGSize(width: size * 2, height: size * 2), // 2x for Retina
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .thumbnail
        )
        
        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            await MainActor.run {
                self.thumbnail = representation.nsImage
                self.isLoading = false
            }
        } catch {
            // Fallback to system icon on error
            await MainActor.run {
                self.isLoading = false
            }
        }
    }
}

// MARK: - Compact Icon View (for smaller displays)

/// A simpler icon view that only shows system file icons without thumbnails.
/// Use this for lists where thumbnails would be too slow or distracting.
struct FileIconView: View {
    let file: FileDescriptor
    let size: CGFloat
    
    init(file: FileDescriptor, size: CGFloat = 24) {
        self.file = file
        self.size = size
    }
    
    var body: some View {
        Image(nsImage: systemIcon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
    
    private var systemIcon: NSImage {
        NSWorkspace.shared.icon(forFile: file.fileURL.path)
    }
}

// MARK: - Preview Provider

struct FileThumbnailView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            // These are placeholder previews - actual file paths would be needed
            Text("FileThumbnailView shows thumbnails for images/PDFs")
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack(spacing: 20) {
                VStack {
                    FileThumbnailView(
                        file: FileDescriptor(
                            fileURL: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
                            fileName: "Finder.app",
                            fileExtension: "app",
                            fileSize: nil,
                            createdAt: nil,
                            modifiedAt: nil,
                            isDirectory: true,
                            isSymlink: false,
                            permissionsReadable: true
                        ),
                        size: 48
                    )
                    Text("Directory")
                        .font(.caption2)
                }
                
                VStack {
                    FileIconView(
                        file: FileDescriptor(
                            fileURL: URL(fileURLWithPath: "/tmp/test.pdf"),
                            fileName: "test.pdf",
                            fileExtension: "pdf",
                            fileSize: 1024,
                            createdAt: nil,
                            modifiedAt: nil,
                            isDirectory: false,
                            isSymlink: false,
                            permissionsReadable: true
                        ),
                        size: 32
                    )
                    Text("PDF Icon")
                        .font(.caption2)
                }
            }
        }
        .padding()
    }
}
