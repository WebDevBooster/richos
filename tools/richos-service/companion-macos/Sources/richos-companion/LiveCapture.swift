import Foundation
import RichOSCompanionCore

/// The live capture loop: wire the Core Audio engine to the SessionWriter, run a 10 Hz mix pump and
/// a 1 Hz health tick + watchdog, and finalize cleanly on Ctrl-C. This is the outside-the-browser
/// watchdog made real (§6.3) — it holds its own timer and alarms on stalls the capture can't hide.
@available(macOS 14.4, *)
func runLiveCapture(zone: String, startedAt: Int64) {
    // session.json is written at START (§6.1) — a call that captures nothing leaves a loud
    // open/empty session on disk, never an absence.
    let params = makeParams(startedAt: startedAt, sampleRate: 48_000)
    let writer = SessionWriter(rootZone: zone, params: params, clock: nowMs)
    do { try writer.start() } catch {
        Notifier.alarm("could not create the session directory: \(error.localizedDescription)")
        exit(1)
    }
    let dir = (zone as NSString).appendingPathComponent(params.sessionId)
    Notifier.info("session (open) written: \(dir)")

    let capture = CoreAudioCapture(writer: writer)
    do {
        try capture.start()
        Notifier.info("capturing system audio + mic. Press Ctrl-C to stop.")
    } catch {
        // The open session.json stays on disk as the anomaly; we exit loud, not silent.
        Notifier.alarm("""
        capture failed to start: \(error.localizedDescription). \
        If this is the first run, grant "System Audio Recording" and Microphone in \
        System Settings > Privacy & Security, then retry. The open session at \(dir) is the on-disk \
        record that this call was NOT captured.
        """)
        exit(1)
    }

    let timerQueue = DispatchQueue(label: "com.richos.companion.timers")

    // 10 Hz mix pump: keep the WAV growing and both sources frame-aligned.
    let pump = DispatchSource.makeTimerSource(queue: timerQueue)
    pump.schedule(deadline: .now() + 0.1, repeating: 0.1)
    pump.setEventHandler { _ = try? writer.pump() }
    pump.resume()

    // 1 Hz health tick + fsync + watchdog escalation.
    var lastBytes = 0
    var stalledSeconds = 0
    let health = DispatchSource.makeTimerSource(queue: timerQueue)
    health.schedule(deadline: .now() + 1.0, repeating: 1.0)
    health.setEventHandler {
        let (mp, mr, sp, sr) = capture.snapshotLevels()
        try? writer.writeHealthTick(
            micPeak: mp, micRms: mr, sysPeak: sp, sysRms: sr,
            tapRunning: capture.tapRunning, micRunning: capture.micRunning)
        try? writer.flush() // durable to disk each second (§6.5)

        // Watchdog: byte growth is the ground-truth liveness signal (§6.2 "no growth > 15 s").
        let bytes = writer.pumpedBytesTotal
        if bytes == lastBytes { stalledSeconds += 1 } else { stalledSeconds = 0 }
        lastBytes = bytes
        if stalledSeconds == 15 {
            Notifier.alarm("no audio has been written for 15s — the capture has stalled (tap stopped, "
                + "device changed, or System Audio Recording permission was revoked). Session: \(dir)")
        }
    }
    health.resume()

    // Clean finalize on SIGINT: drain, flush, rewrite session.json as closed -> triggers P1.
    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: timerQueue)
    sigint.setEventHandler {
        pump.cancel(); health.cancel()
        capture.stop()
        do {
            try writer.close()
            Notifier.info("session (closed) written: \(dir) — the P1 watcher will now transcribe it.")
        } catch {
            Notifier.alarm("failed to finalize session: \(error.localizedDescription)")
        }
        exit(0)
    }
    sigint.resume()

    RunLoop.main.run()
}
