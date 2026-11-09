import CoreAudio
import Foundation

/// Decides when this Mac has really started playing through the headset, per app.
///
/// Watching the device alone isn't enough: a browser tab can hold the output open for hours,
/// stopping and starting it now and then. So only an app that starts after being quiet for a while,
/// and keeps playing for a moment, counts. Apps that were playing when the headset moved to another
/// device are ignored until they stop, so they can't keep pulling it back.
final class MacPlaybackMonitor {
    /// Called once per fresh run of an app's playback, with its bundle ID.
    var onFreshPlayback: ((String) -> Void)?

    private static let pollInterval: TimeInterval = 1
    /// How long an app must have been quiet for its next start to count.
    private static let quietBeforeStart: TimeInterval = 10
    /// How long it must keep playing, so notification sounds don't count.
    private static let minimumPlay: TimeInterval = 2

    private struct Run {
        let bundleID: String
        let started: Date
        let fresh: Bool
        var reported = false
    }

    private let device: AudioDeviceID
    private var timer: Timer?
    private var runs: [pid_t: Run] = [:]
    private var lastStopped: [pid_t: Date] = [:]
    private var ignored: Set<pid_t> = []

    init(device: AudioDeviceID) {
        self.device = device
        // Whatever is already playing when we start watching didn't just start.
        let now = Date()
        for (pid, bundleID) in playing() {
            runs[pid] = Run(bundleID: bundleID, started: now, fresh: false)
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    deinit { timer?.invalidate() }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// The headset moved to another device: leave the apps playing now alone until they stop.
    func ignoreCurrentPlayback() {
        ignored = Set(runs.keys)
        if !ignored.isEmpty {
            Log.debug("Ignoring current Mac playback: " + runs.values.map(\.bundleID).joined(separator: ", "))
        }
    }

    private func playing() -> [pid_t: String] {
        var apps = AudioOutput.playingProcesses(on: device)
        apps[getpid()] = nil   // our own mode-switch sound
        return apps
    }

    private func poll() {
        let now = Date()
        let apps = playing()

        for pid in runs.keys where apps[pid] == nil {
            runs[pid] = nil
            lastStopped[pid] = now
            ignored.remove(pid)
        }
        lastStopped = lastStopped.filter { now.timeIntervalSince($0.value) < 60 }

        for (pid, bundleID) in apps where runs[pid] == nil {
            let quiet = lastStopped[pid].map { now.timeIntervalSince($0) } ?? .infinity
            runs[pid] = Run(bundleID: bundleID, started: now, fresh: quiet >= Self.quietBeforeStart)
        }

        for (pid, run) in runs where run.fresh && !run.reported && !ignored.contains(pid)
            && now.timeIntervalSince(run.started) >= Self.minimumPlay {
            runs[pid]?.reported = true
            onFreshPlayback?(run.bundleID)
        }
    }
}
