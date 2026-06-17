import Foundation

/// Serialize / parse profiles for the Settings window's export & import.
///
/// Two file shapes, both plain JSON:
///  - **single profile** — `{ "schema":1, "kind":"kd100-profile", "name":…, "bindings":{…} }`
///    (shareable: "here's my cTrader pad").
///  - **whole config** — `{ "schema":1, "kind":"kd100-config", "profiles":[ {name,bindings}… ] }`
///    (backup / move to another Mac).
///
/// Each per-key value is a bare string (the **tap** command) or an object
/// `{ "tap":…, "hold":…, "double":… }` when the key also has a long-press / double-tap
/// action — the same shape `mapping.json` uses. `decode` accepts either, plus the legacy
/// flat `{ "bindings":{…} }` (read as `default`), so importing an old hand-written file
/// works. Only known physical-key names survive, so a malformed file can't inject junk.
enum ProfileIO {
    /// Parsed profile: tap commands plus optional sparse hold / double-tap commands.
    typealias Parsed = (name: String, bindings: [String: String],
                        hold: [String: String], double: [String: String])

    static func encodeProfile(name: String, bindings: [String: String],
                              hold: [String: String] = [:], double: [String: String] = [:]) -> Data {
        let obj: [String: Any] = [
            "schema": 1, "kind": "kd100-profile",
            "name": name, "bindings": encodeBindings(tap: bindings, hold: hold, double: double),
        ]
        return json(obj)
    }

    static func encodeAll(_ profiles: [(name: String, bindings: [String: String],
                                        hold: [String: String], double: [String: String])]) -> Data {
        let arr: [[String: Any]] = profiles.map {
            ["name": $0.name, "bindings": encodeBindings(tap: $0.bindings, hold: $0.hold, double: $0.double)]
        }
        let obj: [String: Any] = ["schema": 1, "kind": "kd100-config", "profiles": arr]
        return json(obj)
    }

    /// Convenience overload for callers that only have tap commands (and the test suite).
    static func encodeAll(_ profiles: [(name: String, bindings: [String: String])]) -> Data {
        encodeAll(profiles.map { ($0.name, $0.bindings, [:], [:]) })
    }

    /// Parse a file into an ordered list of profiles to merge. `nil` if the data isn't a
    /// recognizable kd100 file.
    static func decode(_ data: Data) -> [Parsed]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        if let arr = obj["profiles"] as? [[String: Any]] {
            let out: [Parsed] = arr.compactMap { pd in
                guard let n = pd["name"] as? String, !n.isEmpty else { return nil }
                let (t, h, d) = decodeBindings(pd["bindings"] as? [String: Any] ?? [:])
                return (n, t, h, d)
            }
            return out.isEmpty ? nil : out
        }
        if let name = obj["name"] as? String, !name.isEmpty,
           let b = obj["bindings"] as? [String: Any] {
            let (t, h, d) = decodeBindings(b)
            return [(name, t, h, d)]
        }
        if let b = obj["bindings"] as? [String: Any] {   // legacy flat → default
            let (t, h, d) = decodeBindings(b)
            return [("default", t, h, d)]
        }
        return nil
    }

    // MARK: - Internals

    /// Build a bindings dict with values as string (tap only) or `{tap,hold?,double?}`.
    /// Only known physical-key names are emitted.
    private static func encodeBindings(tap: [String: String], hold: [String: String],
                                       double: [String: String]) -> [String: Any] {
        var out: [String: Any] = [:]
        for k in Mapping.order {
            let h = hold[k] ?? "", d = double[k] ?? ""
            if h.isEmpty && d.isEmpty {
                if let t = tap[k] { out[k] = t }           // preserve "" (explicit disable) too
            } else {
                var o: [String: Any] = ["tap": tap[k] ?? ""]
                if !h.isEmpty { o["hold"] = h }
                if !d.isEmpty { o["double"] = d }
                out[k] = o
            }
        }
        return out
    }

    /// Split a raw bindings dict into tap / hold / double, dropping unknown keys and empty
    /// secondary actions.
    private static func decodeBindings(_ raw: [String: Any]) -> (tap: [String: String], hold: [String: String], double: [String: String]) {
        var tap: [String: String] = [:], hold: [String: String] = [:], double: [String: String] = [:]
        for (k, v) in raw where Mapping.order.contains(k) {
            if let s = v as? String {
                tap[k] = s
            } else if let o = v as? [String: Any] {
                tap[k] = (o["tap"] as? String) ?? ""
                if let h = o["hold"] as? String, !h.isEmpty { hold[k] = h }
                if let dd = o["double"] as? String, !dd.isEmpty { double[k] = dd }
            }
        }
        return (tap, hold, double)
    }

    private static func json(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }
}
