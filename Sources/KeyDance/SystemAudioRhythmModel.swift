import AppKit
import Combine

@MainActor
final class SystemAudioRhythmModel: ObservableObject {
    @Published private(set) var state: SystemAudioCapture.State = .stopped
    var onSpectrum: ((AudioSpectrum) -> Void)?
    private let capture = SystemAudioCapture()
    private let processor = AudioSpectrumProcessor()
    private var observation: AnyCancellable?
    private var timer: Timer?
    private var motion = AudioSpectrumMotion()
    private var lastFrameTime: TimeInterval?
    private var startTask: Task<Void, Never>?
    private var enabled = false
    private var suspensions = Set<String>()
    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        let processor = self.processor
        capture.onSamples = { samples, sampleRate in processor.receive(samples, sampleRate: sampleRate) }
        observation = capture.$status.sink { [weak self] state in
            guard let self else { return }
            self.state = state
            if state == .running { self.startPresentation() }
            else { self.stopPresentation() }
        }
        observe(NSWorkspace.willSleepNotification, reason: "sleep", suspended: true)
        observe(NSWorkspace.didWakeNotification, reason: "sleep", suspended: false)
        observe(NSWorkspace.sessionDidResignActiveNotification, reason: "session", suspended: true)
        observe(NSWorkspace.sessionDidBecomeActiveNotification, reason: "session", suspended: false)
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        reconcile()
    }

    func retry() {
        guard enabled else { return }
        reconcile()
    }

    private func reconcile() {
        startTask?.cancel()
        capture.stop()
        guard enabled, suspensions.isEmpty else { return }
        let capture = self.capture
        startTask = Task {
            guard !Task.isCancelled else { return }
            do { try await capture.start() }
            catch { /* Capture publishes a user-facing failure state. */ }
        }
    }

    private func startPresentation() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let elapsed = self.lastFrameTime.map { now - $0 } ?? 1.0 / 60
                self.lastFrameTime = now
                self.onSpectrum?(self.motion.advance(towards: self.processor.snapshot(at: now), elapsed: elapsed))
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPresentation() {
        timer?.invalidate()
        timer = nil
        processor.reset()
        motion = AudioSpectrumMotion()
        lastFrameTime = nil
        onSpectrum?(.silent)
    }

    private func observe(_ name: Notification.Name, reason: String, suspended: Bool) {
        let observer = NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if suspended { self.suspensions.insert(reason) }
                else { self.suspensions.remove(reason) }
                self.reconcile()
            }
        }
        workspaceObservers.append(observer)
    }

    deinit {
        startTask?.cancel()
        timer?.invalidate()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
