import Foundation

/// Publishes the controller's live state to `~/.config/kd100/status.json` so an
/// external status bar (e.g. sketchybar, when the native macOS menu bar is hidden)
/// can show connection + active-profile status without poking at the app.
///
/// The file is rewritten on every health or profile change (and once at startup).
/// It carries no liveness heartbeat — a reader should treat the *process* as the
/// source of truth for "is the app alive" (e.g. `pgrep -x kd100`) and use this
/// file only for the detail (`health`, `profile`). That keeps writes rare (state
/// changes are infrequent) instead of forcing a polling timer just to bump mtime.
///
/// Shape (snake_case, matching the cTrader exporter house style):
/// ```json
/// { "schema": 1, "health": "connected", "detail": "",
///   "profile": "default", "profiles": ["default", "cTrader"], "ts": 1718524800 }
/// ```
/// `health` is one of: connected | waiting | needs_permission | busy | error.
final class StatusExporter {
    private let url: URL

    private var health = "starting"
    private var detail = ""
    private var profile = "default"
    private var profiles: [String] = ["default"]

    init(path: String = NSString(string: "~/.config/kd100/status.json").expandingTildeInPath) {
        url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    /// Record the connection health. `detail` carries the error code for `.error`.
    func setHealth(_ health: String, detail: String = "") {
        self.health = health
        self.detail = detail
        flush()
    }

    /// Record the active profile and the full list of profile names.
    func setProfiles(active: String, all: [String]) {
        profile = active
        profiles = all.isEmpty ? ["default"] : all
        flush()
    }

    private func flush() {
        let obj: [String: Any] = [
            "schema": 1,
            "health": health,
            "detail": detail,
            "profile": profile,
            "profiles": profiles,
            "ts": Int(Date().timeIntervalSince1970),
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.sortedKeys, .prettyPrinted]) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
