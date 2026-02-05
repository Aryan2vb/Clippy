import Foundation

/// Result of a file scan operation containing found files and any errors encountered.
public struct ScanResult: Sendable {
    public let files: [FileDescriptor]
    public let errors: [ScanError]
}

/// A structure representing an error encountered during scanning.
public struct ScanError: Error, Sendable, Identifiable {
    public let id = UUID()
    public let url: URL
    public let message: String
}

/// A scanner handling recursive filesystem scanning.
/// Designed to be detached from UI, efficient, and safe.
public actor FileScanner {
    
    public init() {}
    
    /// Recursively scans the folder at the given URL.
    /// - Parameter folderURL: The root directory to scan.
    /// - Returns: A ScanResult containing all found files and any access errors.
    public func scan(folderURL: URL) async -> ScanResult {
        // We run the blocking I/O on a detached task to avoid blocking the actor or main thread.
        return await Task.detached {
            return self.performScan(at: folderURL)
        }.value
    }
    
    // Internal synchronous helper for the scanning logic
    private nonisolated func performScan(at rootURL: URL) -> ScanResult {
        var files: [FileDescriptor] = []
        
        // Helper class to capture errors from the closure
        class ErrorCollector {
            var errors: [ScanError] = []
            func add(_ error: ScanError) { errors.append(error) }
        }
        let errorCollector = ErrorCollector()
        
        // Security: Ensure we have access if this is a security-scoped URL (e.g. from NSOpenPanel)
        let needsStopAccessing = rootURL.startAccessingSecurityScopedResource()
        defer {
            if needsStopAccessing {
                rootURL.stopAccessingSecurityScopedResource()
            }
        }
        
        // Metadata keys we need to extract
        let keys: [URLResourceKey] = [
            .nameKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
            .isReadableKey
        ]
        
        // Enumeration Options
        // We do NOT use .skipsHiddenFiles because the requirement is to include them.
        // We do not traverse symbolic links by default provided by FileManager, which ensures no infinite recursion loops.
        // We include package descendants to ensure a full "hostile filesystem" scan.
        let options: FileManager.DirectoryEnumerationOptions = []
        
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: options,
            errorHandler: { url, error in
                // Handle permission errors gracefully: record and continue.
                errorCollector.add(ScanError(url: url, message: error.localizedDescription))
                return true // Continue scanning
            }
        ) else {
            return ScanResult(files: [], errors: [ScanError(url: rootURL, message: "Failed to create file enumerator.")])
        }
        
        for case let fileURL as URL in enumerator {
            // Respect cancellation
            if Task.isCancelled { break }
            
            do {
                // Fetch cached resource values.
                // Note: We use the set of keys defined above.
                let resourceValues = try fileURL.resourceValues(forKeys: Set(keys))
                
                let descriptor = FileDescriptor(
                    fileURL: fileURL,
                    fileName: resourceValues.name ?? fileURL.lastPathComponent,
                    fileExtension: fileURL.pathExtension,
                    fileSize: resourceValues.fileSize.map { Int64($0) },
                    createdAt: resourceValues.creationDate,
                    modifiedAt: resourceValues.contentModificationDate,
                    isDirectory: resourceValues.isDirectory ?? false,
                    isSymlink: resourceValues.isSymbolicLink ?? false,
                    permissionsReadable: resourceValues.isReadable ?? false
                )
                
                files.append(descriptor)
                
            } catch {
                // If we fail to read attributes for a file that was enumerated, record it.
                errorCollector.add(ScanError(url: fileURL, message: "Attribute extraction failed: \(error.localizedDescription)"))
            }
        }
        
        return ScanResult(files: files, errors: errorCollector.errors)
    }
}
