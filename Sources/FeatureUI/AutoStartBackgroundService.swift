#if os(iOS) && canImport(BackgroundTasks)
import BackgroundTasks
import Foundation

/// Finite background listening window for armed auto-start detection.
///
/// Rewritten from the prototype's SkateBackgroundArmService (ADR-0004): state-driven
/// instead of a 1 Hz polling loop, no singleton-controller coupling, and honest about the
/// platform contract — raw motion events do NOT wake a suspended app; this only extends a
/// user-initiated armed window while backgrounded, and iOS may cancel it under pressure.
/// On iOS < 26 (no BGContinuedProcessingTask) arming simply pauses in background and
/// resumes on next foreground — the UI says exactly that (06 armed states).
@MainActor
public final class AutoStartBackgroundService {
    public static let shared = AutoStartBackgroundService()

    public static var taskIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "com.example.shred") + ".autostart-listening"
    }

    private var registered = false
    private var pendingContinuation: CheckedContinuation<Void, Never>?
    private var armed = false

    private init() {}

    /// Call once at app launch, before any submit.
    public func register() {
        guard !registered else { return }
        guard #available(iOS 26.0, *) else { return }
        registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier, using: nil
        ) { [weak self] task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor [weak self] in
                await self?.run(continued)
            }
        }
    }

    /// Submit only from a direct user action (arming toggle / Arm button).
    public func submitListeningWindow() {
        guard #available(iOS 26.0, *), registered else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.taskIdentifier,
            title: String(localized: "Auto-start is armed"),
            subtitle: String(localized: "Listening for your push rhythm"))
        request.strategy = .fail
        try? BGTaskScheduler.shared.submit(request)
    }

    /// AppModel reports armed-state transitions; the background task completes itself when
    /// arming ends (session started or disarmed) instead of polling.
    public func armedStateChanged(armed: Bool) {
        self.armed = armed
        if !armed {
            pendingContinuation?.resume()
            pendingContinuation = nil
        }
    }

    @available(iOS 26.0, *)
    private func run(_ task: BGContinuedProcessingTask) async {
        guard armed else {
            task.setTaskCompleted(success: true)
            return
        }
        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.pendingContinuation?.resume()
                self?.pendingContinuation = nil
            }
        }
        // Suspend until arming resolves (detection fired, user disarmed, or expiration).
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            pendingContinuation = c
        }
        task.setTaskCompleted(success: true)
    }
}
#endif
