import Foundation

/// Update check against a small JSON file you host anywhere (make-dmg.sh writes dist/version.json):
///   {"version": "1.0", "build": "20260926.2035", "url": "https://…/A-Train-1.0.dmg", "notes": "what changed"}
/// Nothing is downloaded or installed automatically; the app only tells you and opens the URL.
struct UpdateInfo: Equatable {
    let version: String
    let build: String
    let url: String
    let notes: String
    var label: String { "\(version) (build \(build))" }
}

enum Updates {
    static let urlKey = "updateURL"
    static let lastCheckKey = "lastUpdateCheck"
    static var currentBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0" }
    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// Build numbers are "YYYYMMDD.HHMM" (build.sh); compare them piecewise so "0930" < "2035".
    static func isNewer(_ build: String, than current: String) -> Bool {
        let a = build.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Fetches the JSON; completion on the main thread with (newer-update-or-nil, error).
    static func check(url urlString: String, completion: @escaping (UpdateInfo?, String?) -> Void) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)), ["http", "https", "file"].contains(url.scheme ?? "") else {
            completion(nil, "Update URL is not valid."); return
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("A-Train/\(currentVersion) build \(currentBuild)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            var result: UpdateInfo? = nil
            var error: String? = nil
            if let err = err { error = err.localizedDescription }
            else if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) { error = "HTTP \(http.statusCode)" }
            else if let d = data, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                    let build = j["build"] as? String, let link = j["url"] as? String {
                let info = UpdateInfo(version: j["version"] as? String ?? "?", build: build, url: link, notes: j["notes"] as? String ?? "")
                if isNewer(build, than: currentBuild) { result = info }
            } else { error = "Unexpected response (not the version.json format)." }
            DispatchQueue.main.async {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
                completion(result, error)
            }
        }.resume()
    }
}
