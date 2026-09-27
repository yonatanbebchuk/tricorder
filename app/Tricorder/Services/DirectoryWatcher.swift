import Foundation
import CoreServices

/// FSEvents on work/scans so manifest writes by the pipeline show up in the UI without polling.
final class DirectoryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "backyard.watcher")
    private let handler: @Sendable () -> Void

    init(paths: [String], latency: TimeInterval = 0.8, handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().handler()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents)
        guard let s = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    deinit {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }
}
