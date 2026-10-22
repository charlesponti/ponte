import FluidAudio
import Foundation

// MARK: - Which Parakeet checkpoint

enum ParakeetModel: String, CaseIterable {
    case ultra
    case v3
    case v2
    case redux

    var label: String {
        switch self {
        case .ultra: return "Parakeet Ultra (recommended, 25 languages)"
        case .v3: return "Parakeet TDT v3 (25 languages)"
        case .v2: return "Parakeet TDT v2 (English only)"
        case .redux: return "Parakeet Redux (smallest, 2-bit)"
        }
    }

    var shortLabel: String {
        switch self {
        case .ultra: return "parakeet-ultra"
        case .v3: return "parakeet-tdt-v3"
        case .v2: return "parakeet-tdt-v2"
        case .redux: return "parakeet-redux"
        }
    }

    var version: AsrModelVersion {
        switch self {
        case .ultra: return .ultra
        case .v3: return .v3
        case .v2: return .v2
        case .redux: return .redux
        }
    }
}

// MARK: - Engine selection

enum AsrEngineKind: String, CaseIterable {
    case whisper
    case parakeet

    var label: String {
        switch self {
        case .whisper: return "whisper.cpp (CPU, large-v3-turbo)"
        case .parakeet: return "Parakeet on the Neural Engine (CoreML)"
        }
    }
}

/// Single entry point used by the app and the CLI. Keeps the whisper.cpp path
/// untouched as a fallback, so switching engines is one setting.
enum AsrEngine {
    static func transcribe(wav: URL, progress: ((String) -> Void)? = nil) throws -> Transcriber.Result {
        try transcribe(wav: wav,
                       engine: Settings.engine,
                       parakeetModel: Settings.parakeetModel,
                       language: Settings.language,
                       progress: progress)
    }

    /// Explicit form used by the CLI so flags don't have to mutate app settings.
    static func transcribe(wav: URL,
                           engine: AsrEngineKind,
                           parakeetModel: ParakeetModel,
                           language: String,
                           progress: ((String) -> Void)? = nil) throws -> Transcriber.Result {
        switch engine {
        case .whisper:
            return try Transcriber.transcribe(wav: wav, language: language)
        case .parakeet:
            return try ParakeetEngine.shared.transcribe(
                wav: wav,
                model: parakeetModel,
                language: ParakeetEngine.languageHint(language),
                progress: progress
            )
        }
    }
}

// MARK: - Parakeet

/// Wraps FluidAudio's `AsrManager` and keeps the loaded CoreML models resident,
/// so only the first transcription pays the model-load cost.
final class ParakeetEngine {
    static let shared = ParakeetEngine()

    private let lock = NSLock()
    private var manager: AsrManager?
    private var loadedModel: ParakeetModel?
    private var loadTask: Task<AsrManager, Error>?
    private var loadingModel: ParakeetModel?

    var modelsRoot: URL {
        AsrModels.defaultCacheDirectory(for: .ultra).deletingLastPathComponent()
    }

    func isInstalled(_ model: ParakeetModel) -> Bool {
        let dir = AsrModels.defaultCacheDirectory(for: model.version)
        return AsrModels.modelsExist(at: dir, version: model.version)
    }

    func installPath(_ model: ParakeetModel) -> URL {
        AsrModels.defaultCacheDirectory(for: model.version)
    }

    static func languageHint(_ code: String) -> Language? {
        switch code {
        case "en": return .english
        case "es": return .spanish
        case "fr": return .french
        case "de": return .german
        case "it": return .italian
        case "pt": return .portuguese
        case "nl": return .dutch
        case "da": return .danish
        case "sv": return .swedish
        case "fi": return .finnish
        case "hu": return .hungarian
        case "ro": return .romanian
        default: return nil   // "auto" and anything we don't map
        }
    }

    // MARK: Synchronous facade

    /// Blocking wrapper. Call from a background queue (the app does; the CLI does).
    func transcribe(wav: URL,
                    model: ParakeetModel,
                    language: Language?,
                    progress: ((String) -> Void)?) throws -> Transcriber.Result {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()

        Task.detached(priority: .userInitiated) {
            do {
                let result = try await self.run(wav: wav, model: model, language: language, progress: progress)
                box.set(.success(result))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }

        semaphore.wait()
        return try box.get()
    }

    func download(model: ParakeetModel, progress: ((String) -> Void)?) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()

        Task.detached(priority: .utility) {
            do {
                _ = try await AsrModels.downloadAndLoad(
                    version: model.version,
                    progressHandler: Self.handler(progress)
                )
                box.set(.success(.init(text: "", seconds: 0)))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }

        semaphore.wait()
        _ = try box.get()
    }

    /// Warm the engine up front (the first ANE load in a process can take ~20 s
    /// while CoreML specialises the programme for the Neural Engine).
    func preload(model: ParakeetModel, progress: ((String) -> Void)? = nil) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()

        Task.detached(priority: .utility) {
            let started = Date()
            do {
                _ = try await self.asrManager(for: model, progress: progress)
                vlog(String(format: "parakeet preload took %.1fs", Date().timeIntervalSince(started)))
                box.set(.success(.init(text: "", seconds: 0)))
            } catch {
                vlog("parakeet preload failed: \(error.localizedDescription)")
                box.set(.failure(error))
            }
            semaphore.signal()
        }

        semaphore.wait()
        _ = try box.get()
    }

    /// Release the resident CoreML models (measured in tenths of a GB).
    func unload() {
        lock.lock()
        let existing = manager
        manager = nil
        loadedModel = nil
        loadTask = nil
        loadingModel = nil
        lock.unlock()
        if let existing {
            Task.detached { await existing.cleanup() }
        }
    }

    // MARK: Internals

    private func run(wav: URL,
                     model: ParakeetModel,
                     language: Language?,
                     progress: ((String) -> Void)?) async throws -> Transcriber.Result {
        let started = Date()
        let asr = try await asrManager(for: model, progress: progress)
        var state = try TdtDecoderState()
        let result = try await asr.transcribe(wav, decoderState: &state, language: language)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        vlog(String(format: "parakeet %@ text=%d chars confidence=%.2f audio=%.1fs",
                    model.shortLabel, text.count, result.confidence, result.duration))
        return Transcriber.Result(
            text: text,
            seconds: Date().timeIntervalSince(started),
            engine: model.shortLabel,
            confidence: result.confidence
        )
    }

    private func asrManager(for model: ParakeetModel,
                            progress: ((String) -> Void)?) async throws -> AsrManager {
        lock.lock()
        if let manager, loadedModel == model {
            lock.unlock()
            return manager
        }
        // One load at a time: a launch-time preload and a dictation can race.
        if let loadTask, loadingModel == model {
            lock.unlock()
            return try await loadTask.value
        }
        let installed = isInstalled(model)
        lock.unlock()

        progress?(installed ? "Loading Parakeet models…" : "Downloading Parakeet models…")
        vlog("parakeet load start model=\(model.shortLabel) installed=\(installed)")

        let task = Task { () throws -> AsrManager in
            let models = try await AsrModels.downloadAndLoad(
                version: model.version,
                progressHandler: Self.handler(progress)
            )
            return AsrManager(config: .default, models: models)
        }

        lock.lock()
        loadTask = task
        loadingModel = model
        lock.unlock()

        do {
            let fresh = try await task.value
            lock.lock()
            let old = manager
            manager = fresh
            loadedModel = model
            loadTask = nil
            loadingModel = nil
            lock.unlock()
            if let old { await old.cleanup() }
            vlog("parakeet models ready model=\(model.shortLabel)")
            return fresh
        } catch {
            lock.lock()
            loadTask = nil
            loadingModel = nil
            lock.unlock()
            throw error
        }
    }

    private static func handler(_ progress: ((String) -> Void)?) -> ProgressHandler? {
        guard let progress else { return nil }
        // FluidAudio emits progress from several threads and repeats states; without
        // dedupe the HUD flickers through identical lines during a download.
        let dedupe = ProgressDedupe(progress)
        return { update in
            let pct = Int((update.fractionCompleted * 100).rounded())
            switch update.phase {
            case .listing:
                dedupe.emit("Listing Parakeet model files…")
            case .downloading(let done, let total):
                dedupe.emit("Downloading Parakeet models… \(pct)% (\(done)/\(total) files)")
            case .compiling(let name):
                let label = name.isEmpty ? "model" : name
                dedupe.emit("Compiling \(label) for the Neural Engine…")
            }
        }
    }
}

/// Forwards only changes in the progress text, at most a few times a second.
private final class ProgressDedupe: @unchecked Sendable {
    private let lock = NSLock()
    private var last: String?
    private var lastEmit = Date.distantPast
    private let sink: (String) -> Void

    init(_ sink: @escaping (String) -> Void) {
        self.sink = sink
    }

    func emit(_ message: String) {
        lock.lock()
        let now = Date()
        if message == last, now.timeIntervalSince(lastEmit) < 1.0 {
            lock.unlock()
            return
        }
        last = message
        lastEmit = now
        lock.unlock()
        sink(message)
    }
}

/// Tiny lock-protected box so the detached task's result crosses back safely.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Transcriber.Result, Error>?

    func set(_ result: Result<Transcriber.Result, Error>) {
        lock.lock()
        value = result
        lock.unlock()
    }

    func get() throws -> Transcriber.Result {
        lock.lock()
        defer { lock.unlock() }
        guard let value else { throw PonteError.transcriptionFailed("engine returned nothing") }
        return try value.get()
    }
}
