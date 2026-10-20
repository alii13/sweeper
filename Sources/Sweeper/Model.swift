import Foundation

enum Rules {
    static let idleDays = 7
    static let rustIdleDays = 3
}

struct PR: Hashable {
    let number: Int
    let state: String
    let url: String
    let title: String
    let headOid: String
}

struct Worktree: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let repo: String
    let gitDir: String
    let branch: String?
    let head: String
    let isMain: Bool
    let locked: Bool
    var pr: PR?
    var totalKB: Int?
    var nodeKB = 0
    var rustKB = 0
    var nodePaths: [String] = []
    var rustPaths: [String] = []
    var lastUsed: Date?
    var dirty: Int?
    var unpushed: Int?
    var running = false

    var name: String { (path as NSString).lastPathComponent }
    var repoName: String { (repo as NSString).lastPathComponent }
    var loaded: Bool { totalKB != nil && dirty != nil && unpushed != nil }
    var idleDays: Int? { lastUsed.map { Int(Date().timeIntervalSince($0) / 86_400) } }

    var staleReason: String? {
        if pr?.state == "MERGED" { return "PR merged" }
        if pr?.state == "CLOSED" { return "PR closed" }
        if let d = idleDays, d >= Rules.idleDays { return "idle \(d)d" }
        return nil
    }

    var blockers: [String] {
        var b: [String] = []
        if isMain { b.append("main checkout") }
        if locked { b.append("locked") }
        if running { b.append("in use") }
        if let d = dirty, d > 0 { b.append("\(d) uncommitted") }
        if let u = unpushed, u > 0 { b.append("\(u) unpushed") }
        return b
    }

    /// Removing loses nothing git knows about: no uncommitted files, every commit is on a remote or in the PR.
    var isSafe: Bool { loaded && blockers.isEmpty }
    var isSweepable: Bool { isSafe && staleReason != nil }

    var sizeKey: Int { totalKB ?? -1 }
    var lastUsedKey: Double { lastUsed?.timeIntervalSince1970 ?? 0 }
    var prKey: String { pr?.state ?? "" }
}

struct CacheItem: Identifiable {
    enum Clear { case delete([String]), command([String]) }
    let id: String
    let title: String
    let detail: String
    let paths: [String]
    let clear: Clear
    var kb: Int?
}

private let byteFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowsNonnumericFormatting = false
    return f
}()

func formatKB(_ kb: Int) -> String { byteFormatter.string(fromByteCount: Int64(kb) * 1024) }

func formatBytes(_ b: Int64) -> String { byteFormatter.string(fromByteCount: b) }

func selfTest() {
    func wt(pr: String? = nil, idle: Int = 0, dirty: Int = 0, unpushed: Int = 0, running: Bool = false, main: Bool = false) -> Worktree {
        var w = Worktree(path: "/x", repo: "/r", gitDir: "/r/.git", branch: "b", head: "h", isMain: main, locked: false)
        w.pr = pr.map { PR(number: 1, state: $0, url: "", title: "", headOid: "h") }
        w.totalKB = 1
        w.lastUsed = Date().addingTimeInterval(-Double(idle) * 86_400 - 60)
        w.dirty = dirty
        w.unpushed = unpushed
        w.running = running
        return w
    }
    assert(wt(pr: "MERGED").isSweepable)
    assert(wt(pr: "CLOSED").isSweepable)
    assert(wt(idle: 10).isSweepable)
    assert(!wt(idle: 2).isSweepable, "recent, no PR")
    assert(!wt(pr: "OPEN").isSweepable)
    assert(!wt(pr: "MERGED", dirty: 1).isSweepable)
    assert(!wt(pr: "MERGED", unpushed: 2).isSweepable)
    assert(!wt(pr: "MERGED", running: true).isSweepable)
    assert(!wt(pr: "MERGED", main: true).isSweepable)
    var unmeasured = wt(pr: "MERGED")
    unmeasured.dirty = nil
    assert(!unmeasured.isSweepable, "unknown state must fail closed")
    print("selftest ok")
}
