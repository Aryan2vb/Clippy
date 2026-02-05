import Foundation

/// A clean, immutable data model representing a file in the filesystem.
/// Strictly data-only with no behavior logic.
public struct FileDescriptor: Sendable, Hashable, Identifiable {
    public let id: URL // Use URL as identity mostly, or we could add a UUID if requested. Using URL for now as it's unique per snapshot.
    public let fileURL: URL
    public let fileName: String
    public let fileExtension: String
    public let fileSize: Int64?
    public let createdAt: Date?
    public let modifiedAt: Date?
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let permissionsReadable: Bool

    // Custom init to ensure all fields are populated explicitly
    public init(
        fileURL: URL,
        fileName: String,
        fileExtension: String,
        fileSize: Int64?,
        createdAt: Date?,
        modifiedAt: Date?,
        isDirectory: Bool,
        isSymlink: Bool,
        permissionsReadable: Bool
    ) {
        self.id = fileURL
        self.fileURL = fileURL
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.fileSize = fileSize
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.permissionsReadable = permissionsReadable
    }
}
