import Foundation

/// Where the pipeline runs and where the record (work/environments) lives: this Mac's checkout, or another Mac on the
/// tailnet reached over SSH.  With a remote host the app shows a local *mirror* of that Mac's work/environments
/// (manifests, logs, previews, deliverables; not the dense clouds, meshes, databases and videos) and sends every
/// command over SSH; runs there are detached, so closing this app or the laptop never touches them.
struct RemoteHost: Codable, Hashable, Sendable {
    var host: String        // Tailscale name or address: "macmini", "macmini.tail0ceb9f.ts.net", "100.86.180.26"
    var user: String        // the account on that Mac
    var path: String        // the tricorder checkout there, with its .venv: "/Users/me/Projects/tricorder"

    var address: String { "\(user)@\(host)" }
    var label: String { host.split(separator: ".").first.map(String.init) ?? host }

    /// The local folder that mirrors this host's work/environments, under Application Support.
    var mirror: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let safe = host.replacing(/[^A-Za-z0-9.-]/, with: "_")
        return base.appending(path: "Tricorder/mirrors/\(safe)")
    }
}

enum Compute: Hashable, Sendable {
    case local(URL)
    case remote(RemoteHost)

    static let key = "compute"
    static let rootKey = "projectRoot"

    /// The directory the app reads work/environments under: the checkout, or the host's mirror.
    var root: URL {
        switch self {
        case .local(let u): u
        case .remote(let h): h.mirror
        }
    }

    var remote: RemoteHost? { if case .remote(let h) = self { h } else { nil } }

    static func load() -> Compute? {
        let d = UserDefaults.standard
        if let data = d.data(forKey: key), let h = try? JSONDecoder().decode(RemoteHost.self, from: data) { return .remote(h) }
        if let s = d.string(forKey: Compute.rootKey) { return .local(URL(filePath: s)) }
        return nil
    }

    func save() {
        let d = UserDefaults.standard
        switch self {
        case .local(let u):
            d.set(u.path, forKey: Compute.rootKey)
            d.removeObject(forKey: Compute.key)
        case .remote(let h):
            d.set(try? JSONEncoder().encode(h), forKey: Compute.key)
        }
    }
}
