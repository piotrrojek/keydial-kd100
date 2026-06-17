import Foundation

/// Serialize / parse profiles for the Settings window's export & import.
///
/// Two file shapes, both plain JSON:
///  - **single profile** — `{ "schema":1, "kind":"kd100-profile", "name":…, "bindings":{…} }`
///    (shareable: "here's my cTrader pad").
///  - **whole config** — `{ "schema":1, "kind":"kd100-config", "profiles":[ {name,bindings}… ] }`
///    (backup / move to another Mac).
///
/// `decode` accepts either, plus the legacy flat `{ "bindings":{…} }` (read as `default`),
/// so importing an old hand-written `mapping.json` works. Only known physical-key names
/// survive, so a malformed file can't inject junk keys.
enum ProfileIO {
    static func encodeProfile(name: String, bindings: [String: String]) -> Data {
        let obj: [String: Any] = [
            "schema": 1, "kind": "kd100-profile",
            "name": name, "bindings": clean(bindings),
        ]
        return json(obj)
    }

    static func encodeAll(_ profiles: [(name: String, bindings: [String: String])]) -> Data {
        let arr: [[String: Any]] = profiles.map { ["name": $0.name, "bindings": clean($0.bindings)] }
        let obj: [String: Any] = ["schema": 1, "kind": "kd100-config", "profiles": arr]
        return json(obj)
    }

    /// Parse a file into an ordered list of `(name, bindings)` to merge. `nil` if the
    /// data isn't a recognizable kd100 file.
    static func decode(_ data: Data) -> [(name: String, bindings: [String: String])]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        if let arr = obj["profiles"] as? [[String: Any]] {
            let out: [(String, [String: String])] = arr.compactMap { pd in
                guard let n = pd["name"] as? String, !n.isEmpty else { return nil }
                return (n, clean(pd["bindings"] as? [String: String] ?? [:]))
            }
            return out.isEmpty ? nil : out
        }
        if let name = obj["name"] as? String, !name.isEmpty,
           let b = obj["bindings"] as? [String: String] {
            return [(name, clean(b))]
        }
        if let b = obj["bindings"] as? [String: String] {   // legacy flat → default
            return [("default", clean(b))]
        }
        return nil
    }

    // MARK: - Internals

    private static func clean(_ b: [String: String]) -> [String: String] {
        b.filter { Mapping.order.contains($0.key) }
    }

    private static func json(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }
}
