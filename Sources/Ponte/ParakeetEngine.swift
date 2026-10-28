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

/// Single entry point used by the app and the CLI.
///
/// Parakeet is the only engine. whisper.cpp used to sit beside it as an alternative in the Engine menu, and was
/// removed because it needed a separate Homebrew install: on any machine without one, the menu item answered
/// `whisper-cli not found (brew install whisper-cpp)`, which is a support ticket rather than a feature. It also
/// cost a 1.5 GB model download and 1.9 GB resident to be slower and no more accurate on the material that was
/// measured. The numbers that made Parakeet the default are kept in docs/measurements.md, and
/// scripts/long-dictation-check.sh still measures the behaviour that mattered.
enum AsrEngine {
    static func transcribe(wav: URL, progress: ((String) -> Void)? = nil) throws -> Transcriber.Result {
        try transcribe(wav: wav,
                       parakeetModel: Settings.parakeetModel,
                       language: Settings.language,
                       progress: progress)
    }

    /// Explicit form used by the CLI so flags don't have to mutate app settings.
    static func transcribe(wav: URL,
                           parakeetModel: ParakeetModel,
                           language: String,
                           progress: ((String) -> Void)? = nil) throws -> Transcriber.Result {
        try ParakeetEngine.shared.transcribe(
            wav: wav,
            model: parakeetModel,
            language: ParakeetEngine.languageHint(language),
            progress: progress
        )
    }
}

// MARK: - Parakeet

/// Wraps FluidAudio's `AsrManager` and keeps the loaded CoreML models resident,
/// so only the first transcription pays the model-load cost.
final class ParakeetEngine {
    private enum ManagerLoad {
        case ready(AsrManager)
        case loading(Task<AsrManager, Error>, model: ParakeetModel, ticket: UUID)
    }

    private enum Installation {
        case existing(AsrManager)
        case stale(cleanup: Bool)
        case installed(old: AsrManager?)
    }

    static let shared = ParakeetEngine()

    private let lock = NSLock()
    private var manager: AsrManager?
    private var loadedModel: ParakeetModel?
    private var loadTask: Task<AsrManager, Error>?
    private var loadingModel: ParakeetModel?
    private var loadTicket: UUID?
    private var discardedLoadTickets: Set<UUID> = []

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
                _ = try await AsrModels.download(
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
        let pending = loadTask
        loadTicket = UUID()
        manager = nil
        loadedModel = nil
        loadTask = nil
        loadingModel = nil
        lock.unlock()
        pending?.cancel()
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
        while true {
            let state = lock.withLock { () -> ManagerLoad in
                if let manager, loadedModel == model { return .ready(manager) }
                if let task = loadTask, let activeModel = loadingModel, let ticket = loadTicket {
                    return .loading(task, model: activeModel, ticket: ticket)
                }

                // Publish the task while holding the lock. Creating it after unlocking left a race where two
                // callers both observed an empty slot and each started a full model load.
                let ticket = UUID()
                let installed = isInstalled(model)
                let task = Task { () throws -> AsrManager in
                    progress?(installed ? "Loading Parakeet models…" : "Downloading Parakeet models…")
                    vlog("parakeet load start model=\(model.shortLabel) installed=\(installed)")
                    let models = try await AsrModels.downloadAndLoad(
                        version: model.version,
                        progressHandler: Self.handler(progress)
                    )
                    return AsrManager(config: .default, models: models)
                }
                loadTask = task
                loadingModel = model
                loadTicket = ticket
                return .loading(task, model: model, ticket: ticket)
            }

            switch state {
            case .ready(let manager):
                return manager
            case .loading(let task, let activeModel, let ticket):
                do {
                    // All callers await the same task. Any waiter may install its result, so a cancelled or
                    // delayed initiating caller cannot strand a completed model load.
                    let fresh = try await task.value
                    let installed = try await install(fresh, model: activeModel, ticket: ticket)
                    if activeModel == model { return installed }
                } catch {
                    clearFailedLoad(ticket: ticket)
                    if activeModel == model { throw error }
                }
                continue
            }
        }
    }

    private func install(_ fresh: AsrManager, model: ParakeetModel, ticket: UUID) async throws -> AsrManager {
        let result = lock.withLock { () -> Installation in
            if let manager, loadedModel == model { return .existing(manager) }
            guard loadTicket == ticket else {
                return .stale(cleanup: discardedLoadTickets.insert(ticket).inserted)
            }
            let old = manager
            manager = fresh
            loadedModel = model
            loadTask = nil
            loadingModel = nil
            return .installed(old: old)
        }

        switch result {
        case .existing(let manager):
            return manager
        case .stale(let shouldClean):
            if shouldClean { await fresh.cleanup() }
            throw CancellationError()
        case .installed(let old):
            if let old { await old.cleanup() }
            vlog("parakeet models ready model=\(model.shortLabel)")
            return fresh
        }
    }

    private func clearFailedLoad(ticket: UUID) {
        lock.lock()
        if loadTicket == ticket {
            loadTask = nil
            loadingModel = nil
        }
        lock.unlock()
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
