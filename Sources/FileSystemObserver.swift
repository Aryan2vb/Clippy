import Foundation

// MARK: - FileSystem Event Model

/// A normalized representation of a filesystem event.
///
/// Important: Events are hints, not facts.
/// - Events may arrive late, duplicated, or out of order.
/// - The file may no longer exist by the time you process the event.
/// - Multiple rapid changes may collapse into a single event.
/// - Do NOT assume file existence, completeness, or stability.
public struct FileSystemEvent: Sendable {
    public let affectedURL: URL
    public let eventType: EventType
    public let timestamp: Date
    public let source: Source
    
    public init(affectedURL: URL, eventType: EventType, timestamp: Date = Date(), source: Source = .filesystem) {
        self.affectedURL = affectedURL
        self.eventType = eventType
        self.timestamp = timestamp
        self.source = source
    }
    
    public enum EventType: String, Sendable {
        case created
        case removed
        case modified
        case renamed
    }
    
    public enum Source: String, Sendable {
        case filesystem
    }
}

// MARK: - Observer Delegate

/// Protocol for receiving filesystem events.
/// Consumers implement this to react to observed changes.
public protocol FileSystemObserverDelegate: AnyObject {
    /// Called when a filesystem event is detected.
    /// Events are hints—verify state before acting.
    func observer(_ observer: FileSystemObserver, didReceive event: FileSystemEvent)
    
    /// Called when observation fails or permissions are lost.
    func observer(_ observer: FileSystemObserver, didEncounterError error: FileSystemObserver.ObserverError)
}

// MARK: - FileSystem Observer

/// Watches user-approved folders for filesystem changes using FSEvents.
///
/// Philosophy:
/// - This subsystem OBSERVES. It does NOT act.
/// - Events are weather reports, not ground truth.
/// - No rescanning, no deduction, no mutation.
///
/// FSEvents notes:
/// - Events may be coalesced (multiple changes → one event).
/// - Events may arrive with latency.
/// - Renamed files appear as remove + create unless using file-level events.
/// - Always treat events as hints requiring verification.
public final class FileSystemObserver {
    
    public enum ObserverError: Error, Sendable {
        case permissionDenied(URL)
        case streamCreationFailed
        case streamStopped
        case unknown(String)
    }
    
    public weak var delegate: FileSystemObserverDelegate?
    
    private var eventStream: FSEventStreamRef?
    private var observedURLs: [URL] = []
    private var isObserving: Bool = false
    
    /// Latency in seconds before FSEvents delivers batched events.
    /// Lower = more responsive, higher CPU. Higher = batched, lower CPU.
    private let latency: CFTimeInterval = 0.5
    
    public init() {}
    
    deinit {
        stopObserving()
    }
    
    // MARK: - Public API
    
    /// Begin observing the specified folder URLs for filesystem events.
    /// - Parameter urls: Folder URLs to observe. Must have read permission.
    public func startObserving(urls: [URL]) {
        guard !isObserving else { return }
        guard !urls.isEmpty else { return }
        
        observedURLs = urls
        
        // Convert URLs to paths for FSEvents
        let paths = urls.map { $0.path } as CFArray
        
        // Context to pass self into the C callback
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        
        // Flags:
        // - kFSEventStreamCreateFlagFileEvents: file-level granularity (not just directory)
        // - kFSEventStreamCreateFlagUseCFTypes: use CF types in callback
        // - kFSEventStreamCreateFlagNoDefer: deliver events immediately (vs batched)
        let flags: FSEventStreamCreateFlags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes
        )
        
        // Create the event stream
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            delegate?.observer(self, didEncounterError: .streamCreationFailed)
            return
        }
        
        eventStream = stream
        
        // Schedule on the main run loop
        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        
        // Start the stream
        if !FSEventStreamStart(stream) {
            delegate?.observer(self, didEncounterError: .streamCreationFailed)
            stopObserving()
            return
        }
        
        isObserving = true
    }
    
    /// Stop observing all folders and release resources.
    public func stopObserving() {
        guard let stream = eventStream else { return }
        
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        
        eventStream = nil
        isObserving = false
        observedURLs = []
    }
    
    // MARK: - Internal Event Processing
    
    /// Called by the FSEvents callback. Parses raw events into normalized model.
    fileprivate func handleRawEvents(
        paths: [String],
        flags: [FSEventStreamEventFlags],
        ids: [FSEventStreamEventId]
    ) {
        for (index, path) in paths.enumerated() {
            let flag = flags[index]
            let url = URL(fileURLWithPath: path)
            
            // Check for special conditions first
            if flag & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                // Events were dropped; a full rescan is recommended.
                // Per spec: we do NOT rescan here. We just note the gap.
                // A consumer may choose to trigger a rescan externally.
                delegate?.observer(self, didEncounterError: .unknown("Events may have been dropped; consider manual rescan."))
                continue
            }
            
            if flag & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
                // The watched root was moved or deleted.
                delegate?.observer(self, didEncounterError: .permissionDenied(url))
                continue
            }
            
            // Determine event type from flags
            // Note: These are hints. The actual state may differ.
            let eventType: FileSystemEvent.EventType
            
            if flag & UInt32(kFSEventStreamEventFlagItemCreated) != 0 {
                eventType = .created
            } else if flag & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 {
                eventType = .removed
            } else if flag & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 {
                // Renamed events come in pairs (old path, new path) but may arrive separately.
                eventType = .renamed
            } else if flag & UInt32(kFSEventStreamEventFlagItemModified) != 0 {
                eventType = .modified
            } else if flag & UInt32(kFSEventStreamEventFlagItemInodeMetaMod) != 0 {
                eventType = .modified
            } else {
                // Unknown or unhandled flag; skip silently.
                continue
            }
            
            let event = FileSystemEvent(
                affectedURL: url,
                eventType: eventType
            )
            
            delegate?.observer(self, didReceive: event)
        }
    }
}

// MARK: - FSEvents C Callback

/// The FSEvents callback function. Called on the run loop when events arrive.
/// This is a C function pointer; it extracts the Swift object from context.
private func fsEventCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    
    let observer = Unmanaged<FileSystemObserver>.fromOpaque(info).takeUnretainedValue()
    
    // Extract paths (depends on kFSEventStreamCreateFlagUseCFTypes)
    let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
    
    // Extract flags and IDs into arrays
    let flags = Array(UnsafeBufferPointer(start: eventFlags, count: numEvents))
    let ids = Array(UnsafeBufferPointer(start: eventIds, count: numEvents))
    
    observer.handleRawEvents(paths: paths, flags: flags, ids: ids)
}

// MARK: - Example Usage

public func observerExample() {
    print("--- FileSystem Observer Example ---")
    
    class ExampleDelegate: FileSystemObserverDelegate {
        func observer(_ observer: FileSystemObserver, didReceive event: FileSystemEvent) {
            print("Event: \(event.eventType.rawValue) at \(event.affectedURL.lastPathComponent)")
        }
        
        func observer(_ observer: FileSystemObserver, didEncounterError error: FileSystemObserver.ObserverError) {
            print("Error: \(error)")
        }
    }
    
    let observer = FileSystemObserver()
    let delegate = ExampleDelegate()
    observer.delegate = delegate
    
    // Start observing the user's Downloads folder
    let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    
    print("Starting observation of: \(downloadsURL.path)")
    observer.startObserving(urls: [downloadsURL])
    
    // In a real app, the run loop would continue.
    // Here we simulate a brief observation window.
    print("Observing for 5 seconds... (create/modify/delete files in Downloads to see events)")
    
    // Run the main run loop for 5 seconds to receive events
    RunLoop.main.run(until: Date().addingTimeInterval(5))
    
    print("Stopping observation.")
    observer.stopObserving()
    
    print("Done.")
}
