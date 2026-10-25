import AVFoundation
import Foundation
import WaveformCapture
import WaveformCore

/// Ponte's capture: the shared engine in `WaveformCapture`, in the configuration on-device
/// transcription wants — a 16 kHz mono 16-bit WAV, exactly what the engine reads, so no
/// conversion step is ever needed.
///
/// This used to be `AVAudioRecorder` plus a 30 Hz dB meter. The engine does both better: real RMS at
/// 120 columns a second with meter ballistics, the same analysis Thames draws its orb from, and the
/// route-change and cut-short handling that comes with it.
final class Recorder {
    private var engine: EngineRecorder?
    private(set) var currentURL: URL?

    /// The recording's columns, newest last: what the orb is drawn from, with the ballistics and the
    /// dB mapping applied by the engine and by `WaveformUI`'s view.
    var columns: ColumnRing? { engine?.columns }

    /// Where the audio's time meets the screen's, so the orb's picture moves smoothly between buffers.
    var clock: StreamClock? { engine?.clock }

    /// The microphone this take is coming from — logged, and part of explaining a quiet take.
    private(set) var deviceName = "unknown"

    /// The loudest sample in the newest column, in dBFS: what `InputWatch` reads.
    var newestPeakDB: Float? {
        guard let ring = engine?.columns else { return nil }
        var column = Column.silent
        let found = withUnsafeMutablePointer(to: &column) { ring.copyLast(1, into: $0) }
        return found > 0 ? InputWatch.peakDB(column) : nil
    }

    var isRecording: Bool { engine != nil }

    /// How much has been recorded, from the frames written rather than from a wall clock.
    var elapsed: TimeInterval { engine?.seconds ?? 0 }

    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { done(ok) }
            }
        default:
            done(false)
        }
    }

    static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func start() throws -> URL {
        // Defensive: never leak a running recording — that leaves a header-only WAV behind and a
        // microphone that stays hot.
        if engine != nil {
            vlog("recorder already running — stopping it before restarting")
            stop()
        }
        // Touching the engine's input node before the grant is not safe.
        guard Self.isAuthorized else { throw PonteError.recordFailed }
        try FileManager.default.createDirectory(at: AppPaths.audio, withIntermediateDirectories: true)

        // Which mic? A pinned device records through the capture session — device-first, so there is no engine graph
        // to disagree with it (#19). No pin keeps the engine path exactly as it was, which is what everyone had before
        // there was a choice. The name logged is resolved through CoreAudio, the same list the window shows.
        let inputs = AudioInputs.available()
        let resolved = AudioInputs.resolve(pinned: Settings.inputDeviceUID,
                                           available: inputs,
                                           defaultUID: AudioInputs.systemDefaultUID())
        var device = resolved.input?.name ?? "unknown"
        if resolved.fellBack, let pin = Settings.inputDeviceUID {
            device += " (\(pin) is not connected)"
            vlog("record: pinned microphone \(pin) is not connected — falling back to \(resolved.input?.name ?? "the system input")")
        }

        let url = AppPaths.audio.appendingPathComponent("rec-\(AppPaths.stamp()).wav")

        let source = AudioSourceChoice.make(settings: .localTranscription, deviceUID: Settings.inputDeviceUID)
        vlog("record: source=\(type(of: source)) pinned=\(Settings.inputDeviceUID ?? "none")")
        let recorder = EngineRecorder(settings: .localTranscription, audioSource: source)
        try recorder.start(to: url)
        engine = recorder
        currentURL = url
        deviceName = device
        vlog("record start device=\(device) file=\(url.lastPathComponent) format=16kHz-mono-wav")
        // The hardware's own answer, asked a second in — a capture session starts asynchronously, so asking now would
        // report nothing and read like a take that never opened a device.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let running = AudioInputs.runningInputNames()
            vlog("record running=\(running.isEmpty ? "none" : running.joined(separator: ", "))")
        }
        return url
    }

    @discardableResult
    func stop() -> URL? {
        let url = currentURL
        let seconds = elapsed
        var incomplete: String?
        do {
            _ = try engine?.stop()
        } catch {
            incomplete = error.localizedDescription
        }
        engine = nil
        currentURL = nil
        if let url {
            vlog(String(format: "record stop file=%@ duration=%.2fs", url.lastPathComponent, seconds))
        }
        if let incomplete { vlog("record incomplete: \(incomplete)") }
        return url
    }
}
