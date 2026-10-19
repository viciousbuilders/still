import Foundation
import Darwin

/// Watch directories so the helper's atomic file replacements remain observable.
@MainActor
final class StateMonitor {
    private let directories: [URL]
    private let changed: () -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    private var fallback: Timer?

    init(directories: [URL], changed: @escaping () -> Void) {
        self.directories = directories; self.changed = changed
        watchDirectories()
        // Recover from missed events, missing directories, or revoked descriptors.
        fallback = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.watchDirectories()
                self?.changed()
            }
        }
        fallback?.tolerance = 5
    }

    deinit {
        pending?.cancel()
        fallback?.invalidate()
        sources.forEach { $0.cancel() }
    }

    private func watchDirectories() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        var watched = Set<String>()
        for directory in directories {
            var path = directory.standardizedFileURL
            var descriptor = open(path.path, O_EVTONLY)
            // Before first use Still's directory may not exist. Watch its nearest
            // existing parent, then reconnect when the helper creates it.
            while descriptor < 0 && path.path != "/" {
                path.deleteLastPathComponent()
                descriptor = open(path.path, O_EVTONLY)
            }
            guard descriptor >= 0 else { continue }
            guard watched.insert(path.path).inserted else { close(descriptor); continue }
            let watchedDescriptor = descriptor
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: watchedDescriptor, eventMask: [.write, .delete, .rename, .revoke], queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in self?.scheduleRefresh() }
            }
            source.setCancelHandler { close(watchedDescriptor) }
            sources.append(source)
            source.resume()
        }
    }

    private func scheduleRefresh() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.watchDirectories()
            self.changed()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
