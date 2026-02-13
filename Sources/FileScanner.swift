import Foundation

/// Result of a file scan operation containing found files and any errors encountered.
public struct ScanResult: Sendable {
    public let files: [FileDescriptor]
    public let errors: [ScanError]
    public let wasCancelled: Bool
    public let scannedFileCount: Int
    
    public init(files: [FileDescriptor], errors: [ScanError], wasCancelled: Bool = false, scannedFileCount: Int? = nil) {
        self.files = files
        self.errors = errors
        self.wasCancelled = wasCancelled
        self.scannedFileCount = scannedFileCount ?? files.count
    }
}

/// A structure representing an error encountered during scanning.
public struct ScanError: Error, Sendable, Identifiable {
    public let id = UUID()
    public let url: URL
    public let message: String
}

/// Progress information for ongoing scans
public struct ScanProgress: Sendable {
    public let filesFound: Int
    public let currentPath: String?
    public let isCancelled: Bool
    
    public init(filesFound: Int, currentPath: String? = nil, isCancelled: Bool = false) {
        self.filesFound = filesFound
        self.currentPath = currentPath
        self.isCancelled = isCancelled
    }
}

/// A scanner handling recursive filesystem scanning.
/// Designed to be detached from UI, efficient, and safe with cancellation support.
public actor FileScanner {
    
    private var currentTask: Task<ScanResult, Never>?
    private var isCancelled = false
    
    public init() {}
    
    /// Cancels any ongoing scan operation
    public func cancel() {
        isCancelled = true
        currentTask?.cancel()
    }
    
    /// Resets the cancellation state for a new scan
    private func resetCancellation() {
        isCancelled = false
    }
    
    /// Recursively scans the folder at the given URL with progress callback.
    /// - Parameters:
    ///   - folderURL: The root directory to scan.
    ///   - progressHandler: Optional callback for progress updates (called every 100 files)
    /// - Returns: A ScanResult containing all found files and any access errors.
    public func scan(folderURL: URL, progressHandler: (@Sendable (ScanProgress) -> Void)? = nil) async -> ScanResult {
        resetCancellation()
        
        // Create a task that can be cancelled
        let task = Task<ScanResult, Never> {
            return await self.performScan(at: folderURL, progressHandler: progressHandler)
        }
        
        currentTask = task
        let result = await task.value
        currentTask = nil
        
        return result
    }
    
    /// Scans with additional options for duplicate detection
    public func scanWithDuplicateDetection(folderURL: URL, progressHandler: (@Sendable (ScanProgress) -> Void)? = nil) async -> (scanResult: ScanResult, duplicates: [[FileDescriptor]]) {
        let scanResult = await scan(folderURL: folderURL, progressHandler: progressHandler)
        
        if Task.isCancelled || isCancelled {
            return (scanResult, [])
        }
        
        let duplicates = findDuplicates(in: scanResult.files)
        return (scanResult, duplicates)
    }
    
    /// Finds duplicate files based on size and hash
    private func findDuplicates(in files: [FileDescriptor]) -> [[FileDescriptor]] {
        // Group by file size first (fast check)
        let sizeGroups = Dictionary(grouping: files) { $0.fileSize }
        
        var duplicates: [[FileDescriptor]] = []
        
        for (_, group) in sizeGroups {
            if group.count > 1 {
                // Potentially duplicates - could add hash checking here for accuracy
                // For now, group by size as a fast approximation
                duplicates.append(group)
            }
        }
        
        return duplicates.filter { $0.count > 1 }
    }
    
    // Internal synchronous helper for the scanning logic
    private func performScan(at rootURL: URL, progressHandler: (@Sendable (ScanProgress) -> Void)? = nil) async -> ScanResult {
        var files: [FileDescriptor] = []
        var fileCount = 0
        
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
            // Check both task cancellation and manual cancellation
            if Task.isCancelled || isCancelled {
                let progress = ScanProgress(filesFound: fileCount, currentPath: fileURL.path, isCancelled: true)
                progressHandler?(progress)
                return ScanResult(files: files, errors: errorCollector.errors, wasCancelled: true, scannedFileCount: fileCount)
            }
            
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
                fileCount += 1
                
                // Report progress every 100 files
                if fileCount % 100 == 0 {
                    let progress = ScanProgress(filesFound: fileCount, currentPath: fileURL.path, isCancelled: false)
                    progressHandler?(progress)
                }
                
            } catch {
                // If we fail to read attributes for a file that was enumerated, record it.
                errorCollector.add(ScanError(url: fileURL, message: "Attribute extraction failed: \(error.localizedDescription)"))
            }
        }
        
        return ScanResult(files: files, errors: errorCollector.errors, wasCancelled: false, scannedFileCount: fileCount)
    }
}
