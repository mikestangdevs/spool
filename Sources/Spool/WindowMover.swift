import ApplicationServices
import CoreGraphics
import Foundation
import SpoolCore

/// Sends window moves to apps off the main thread, one queue per app.
///
/// Each move is a round trip to the app, and a busy app such as a browser can take several
/// milliseconds to answer. Done on the main thread, one slow app holds up every other window
/// and the gesture driving them. Here only the newest frame for a window is ever sent: if the
/// app is still busy with the last one, the frames in between are skipped.
final class WindowMover {
    static let shared = WindowMover()

    private struct Job {
        let element: AXUIElement
        var frame: CGRect
        var resize: Bool
    }

    private let lock = NSLock()
    private var pending: [WindowID: Job] = [:]
    private var busy: Set<WindowID> = []
    private var queues: [pid_t: DispatchQueue] = [:]
    private let group = DispatchGroup()

    func move(_ id: WindowID, _ element: AXUIElement, pid: pid_t, to frame: CGRect, resize: Bool) {
        lock.lock()
        let earlier = pending[id]
        pending[id] = Job(element: element, frame: frame, resize: resize || (earlier?.resize ?? false))
        let start = busy.insert(id).inserted
        let queue = queues[pid] ?? DispatchQueue(label: "spool.mover.\(pid)", qos: .userInteractive)
        queues[pid] = queue
        lock.unlock()
        guard start else { return }
        group.enter()
        queue.async { self.drainWindow(id) }
    }

    private func drainWindow(_ id: WindowID) {
        while true {
            lock.lock()
            guard let job = pending.removeValue(forKey: id) else {
                busy.remove(id)
                lock.unlock()
                group.leave()
                return
            }
            lock.unlock()
            job.element.setPosition(job.frame.origin)
            if job.resize { job.element.setSize(job.frame.size) }
        }
    }

    /// Runs `body` on the main thread once every move sent so far has reached its app.
    func whenIdle(_ body: @escaping () -> Void) {
        group.notify(queue: .main, execute: body)
    }

    /// Waits, briefly, for moves in flight to land.
    func drain() {
        _ = group.wait(timeout: .now() + 1)
    }
}
