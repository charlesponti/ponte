enum CLICommandOptions {
    private static let allowed: [String: Set<String>] = [
        "--help": [], "-h": [], "help": [], "--version": [], "--devices": [], "--download": [], "--selftest": [],
        "--status-icon": [], "--status-image": [], "--icon": [], "--icon-sheet": [],
        "--menubar-mark": [], "--menubar-sheet": [], "--hud-voice": [], "--hud-strip": [],
        "--trim": [],
        "--transcribe": ["--parakeet-model", "--language"],
        "--bench": ["--parakeet-model", "--language"],
        "--record": ["--out", "--language", "--mic", "--live"],
        "--live-file": ["--language"],
        "--hud-render": ["--turning", "--words", "--since", "--rate"],
        "--hud-demo": ["--words"],
        "--settings": ["--theme", "--variant", "--pane"],
        "--history-window": ["--theme", "--variant", "--pane"],
        "--settings-render": ["--out", "--pane"],
    ]

    static func error(command: String, arguments: [String]) -> String? {
        guard let accepted = allowed[command] else { return nil }
        for argument in arguments where argument.hasPrefix("--") && !accepted.contains(argument) {
            return "error: \(argument) is not valid with \(command)"
        }
        return nil
    }
}
