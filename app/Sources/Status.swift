import Foundation

/// Mirror of the JSON the daemon writes to /usr/local/vpn-split/status.json.
struct VPNInfo: Decodable {
    let connected: Bool
    let iface: String?
    let gw: String?
    let local: String?

    enum CodingKeys: String, CodingKey {
        case connected
        case iface = "if"
        case gw
        case local
    }
}

struct EntryStatus: Decodable {
    let raw: String
    let kind: String?
    let enabled: Bool
    let comment: String?
    let ips: [String]?
    let applied: Bool?
    let error: String?
    let resolver: Bool?
    let auto: Bool?
    let via: String?
}

struct DaemonStatus: Decodable {
    let ts: Double
    let daemonVersion: String?
    let vpn: VPNInfo
    let mode: String
    let fullUntil: Double?
    let tiling: Bool?
    let routeCount: Int?
    let publicIp: String?
    let note: String?
    let entries: [EntryStatus]?
    let lastAction: String?

    /// The daemon rewrites status.json on every event and at least every 60 s, so a file older
    /// than 75 s means it is not running.
    var isStale: Bool { Date().timeIntervalSince1970 - ts > 75 }

    static func load(from path: String) -> DaemonStatus? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try? dec.decode(DaemonStatus.self, from: data)
    }
}
