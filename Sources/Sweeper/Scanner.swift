import Foundation

enum Shell {
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.cargo/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        return env
    }()

    @discardableResult
    static func run(_ args: [String], in dir: String? = nil) async -> (ok: Bool, out: String, err: String) {
        await withCheckedContinuation { cont in
            // Dedicated threads, not GCD: each call blocks two threads, and dozens at once exhaust the GCD pool.
            Thread {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = args
                p.environment = environment
                if let dir { p.currentDirectoryURL = URL(fileURLWithPath: dir) }
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch {
                    cont.resume(returning: (false, "", "\(error)"))
                    return
                }
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                Thread {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }.start()
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus == 0,
                                        String(decoding: outData, as: UTF8.self),
                                        String(decoding: errData, as: UTF8.self)))
            }.start()
        }
    }
}

struct Processes {
    let cwds: [String]
    let commands: String

    func uses(_ path: String) -> Bool {
        let prefix = path + "/"
        return cwds.contains { $0 == path || $0.hasPrefix(prefix) } || commands.contains(prefix)
    }
}

enum Scanner {
    static let home = NSHomeDirectory()

    // Privacy-protected folders trigger a macOS permission prompt on first read.
    static let skipped: Set<String> = ["Library", "node_modules", "Pictures", "Music", "Movies", "Desktop", "Documents", "Downloads", "Public", "Applications"]

    // ponytail: walks ~ three levels deep, add roots if worktrees live deeper
    static func discoverRepos() -> [String] {
        let fm = FileManager.default
        var repos = Set<String>()
        var frontier = [home]
        for depth in 0..<3 {
            var next: [String] = []
            for dir in frontier {
                guard let kids = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for kid in kids where !kid.hasPrefix(".") && !skipped.contains(kid) {
                    let path = dir + "/" + kid
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                    var gitIsDir: ObjCBool = false
                    if fm.fileExists(atPath: path + "/.git", isDirectory: &gitIsDir) {
                        if gitIsDir.boolValue { repos.insert(path) }
                        else if let gd = readGitDir(path), let r = gd.range(of: "/.git/worktrees/") {
                            repos.insert(String(gd[..<r.lowerBound]))
                        }
                        continue
                    }
                    if depth < 2 { next.append(path) }
                }
            }
            frontier = next
        }
        return repos.sorted()
    }

    static func readGitDir(_ worktree: String) -> String? {
        guard let text = try? String(contentsOfFile: worktree + "/.git", encoding: .utf8),
              text.hasPrefix("gitdir: ") else { return nil }
        let dir = text.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
        return dir.hasPrefix("/") ? dir : URL(fileURLWithPath: worktree + "/" + dir).standardizedFileURL.path
    }

    static func worktrees(repo: String) async -> [Worktree] {
        let out = await Shell.run(["git", "-C", repo, "worktree", "list", "--porcelain"]).out
        var list: [Worktree] = []
        for (i, block) in out.components(separatedBy: "\n\n").enumerated() {
            var path: String?, head = "", branch: String?, locked = false, skip = false
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
                else if line.hasPrefix("HEAD ") { head = String(line.dropFirst(5)) }
                else if line.hasPrefix("branch ") { branch = String(line.dropFirst(7).replacingOccurrences(of: "refs/heads/", with: "")) }
                else if line.hasPrefix("locked") { locked = true }
                else if line.hasPrefix("prunable") || line == "bare" { skip = true }
            }
            guard let path, !skip, FileManager.default.fileExists(atPath: path) else { continue }
            let isMain = i == 0
            guard let gitDir = isMain ? repo + "/.git" : readGitDir(path) else { continue }
            list.append(Worktree(path: path, repo: repo, gitDir: gitDir, branch: branch, head: head, isMain: isMain, locked: locked))
        }
        return list.count > 1 ? list : []
    }

    static func pullRequests(repo: String) async -> [String: PR] {
        struct Raw: Decodable {
            let number: Int
            let state, headRefName, headRefOid, url, title, updatedAt: String
        }
        let r = await Shell.run(["gh", "pr", "list", "--state", "all", "--limit", "1000",
                                 "--json", "number,state,headRefName,headRefOid,url,title,updatedAt"], in: repo)
        guard r.ok, let raws = try? JSONDecoder().decode([Raw].self, from: Data(r.out.utf8)) else { return [:] }
        var map: [String: PR] = [:]
        for raw in raws.sorted(by: { $0.updatedAt > $1.updatedAt }) where map[raw.headRefName] == nil {
            map[raw.headRefName] = PR(number: raw.number, state: raw.state, url: raw.url, title: raw.title, headOid: raw.headRefOid)
        }
        return map
    }

    static func baseRows() async -> [Worktree] {
        let repos = await Task.detached { discoverRepos() }.value
        return await withTaskGroup(of: [Worktree].self) { group in
            for repo in repos {
                group.addTask {
                    let rows = await worktrees(repo: repo)
                    guard !rows.isEmpty else { return [] }
                    let prs = await pullRequests(repo: repo)
                    return rows.map { w in
                        var w = w
                        w.pr = w.branch.flatMap { prs[$0] }
                        return w
                    }
                }
            }
            var all: [Worktree] = []
            for await rows in group { all += rows }
            return all
        }
    }

    static func processes() async -> Processes {
        async let lsof = Shell.run(["lsof", "-d", "cwd", "-Fn"])
        async let ps = Shell.run(["ps", "-axww", "-o", "command="])
        let cwds = await lsof.out.split(separator: "\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
        return Processes(cwds: cwds, commands: await ps.out)
    }

    static func du(_ paths: [String]) async -> Int {
        guard !paths.isEmpty else { return 0 }
        let out = await Shell.run(["du", "-sk"] + paths).out
        return out.split(separator: "\n").compactMap { Int($0.split(separator: "\t").first ?? "") }.reduce(0, +)
    }

    /// The fields that decide whether removing loses work. Cheap enough to re-run right before a delete.
    static func safety(_ w: Worktree, _ procs: Processes) async -> Worktree {
        var w = w
        let path = w.path
        async let status = Shell.run(["git", "--no-optional-locks", "-C", path, "status", "--porcelain"])
        async let ahead = Shell.run(["git", "-C", path, "rev-list", "--count", "HEAD", "--not", "--remotes"])
        let s = await status, a = await ahead
        w.dirty = s.ok ? s.out.split(separator: "\n").count : nil
        w.unpushed = a.ok ? Int(a.out.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
        // A squash-merged branch whose remote was pruned still has its commits on GitHub, in the PR.
        if w.pr?.headOid == w.head { w.unpushed = 0 }
        w.running = procs.uses(w.path)
        return w
    }

    static func measure(_ w: Worktree, _ procs: Processes) async -> Worktree {
        var w = await safety(w, procs)
        let found = await Shell.run(["find", w.path, "-type", "d", "(", "-name", "node_modules", "-o", "-name", "target", ")", "-prune", "-print"]).out
        let dirs = found.split(separator: "\n").map(String.init)
        w.nodePaths = dirs.filter { $0.hasSuffix("/node_modules") }
        // Only cargo output: cargo writes CACHEDIR.TAG into every target dir it owns.
        w.rustPaths = dirs.filter { $0.hasSuffix("/target") && FileManager.default.fileExists(atPath: $0 + "/CACHEDIR.TAG") }
        let nodePaths = w.nodePaths, rustPaths = w.rustPaths, path = w.path
        async let node = du(nodePaths)
        async let rust = du(rustPaths)
        async let total = du([path])
        w.nodeKB = await node
        w.rustKB = await rust
        w.totalKB = await total
        let fm = FileManager.default
        w.lastUsed = ["HEAD", "logs/HEAD"]
            .compactMap { try? fm.attributesOfItem(atPath: w.gitDir + "/" + $0)[.modificationDate] as? Date }
            .max()
        return w
    }

    static func measureAll(_ rows: [Worktree], _ procs: Processes, onEach: @escaping (Worktree) async -> Void = { _ in }) async -> [Worktree] {
        await withTaskGroup(of: Worktree.self) { group in
            var pending = rows[...]
            for _ in 0..<6 {
                if let w = pending.popFirst() { group.addTask { await measure(w, procs) } }
            }
            var done: [Worktree] = []
            for await w in group {
                done.append(w)
                await onEach(w)
                if let next = pending.popFirst() { group.addTask { await measure(next, procs) } }
            }
            return done
        }
    }

    static let trashRoot = home + "/.sweeper-trash"

    /// Moves the worktree (or, for a main checkout, the whole repo) out of the way in one rename, then
    /// unregisters it. Deleting the files is the slow part, so the caller does that with `purge`.
    static func remove(_ w: Worktree) async -> (trash: String?, err: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: trashRoot, withIntermediateDirectories: true)
        let dest = trashRoot + "/" + UUID().uuidString
        if w.locked { await Shell.run(["git", "-C", w.repo, "worktree", "unlock", w.path]) }
        do {
            try fm.moveItem(atPath: w.path, toPath: dest)
        } catch {
            // A different volume cannot be renamed into ~; delete in place instead.
            let r = await Shell.run(["rm", "-rf", w.path])
            guard r.ok else { return (nil, r.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if !w.isMain { await Shell.run(["git", "-C", w.repo, "worktree", "prune"]) }
            return (nil, "")
        }
        if !w.isMain { await Shell.run(["git", "-C", w.repo, "worktree", "prune"]) }
        return (dest, "")
    }

    static func purge(_ paths: [String]) async {
        guard !paths.isEmpty else { return }
        if !(await Shell.run(["rm", "-rf"] + paths)).ok {
            // Read-only directories (e.g. Go's module cache) refuse deletes until made writable.
            await Shell.run(["chmod", "-R", "u+w"] + paths)
            await Shell.run(["rm", "-rf"] + paths)
        }
    }

    /// Finishes deletes a previous run was interrupted in.
    static func purgeLeftovers() async {
        let kids = (try? FileManager.default.contentsOfDirectory(atPath: trashRoot)) ?? []
        await purge(kids.map { trashRoot + "/" + $0 })
    }

    /// What deleting a whole repo loses that no remote has: commits on local-only branches, and stashes.
    static func repoLoss(_ repo: String) async -> (commits: Int, stashes: Int) {
        async let commits = Shell.run(["git", "-C", repo, "rev-list", "--count", "--branches", "--not", "--remotes"])
        async let stashes = Shell.run(["git", "-C", repo, "stash", "list"])
        return (Int(await commits.out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0,
                await stashes.out.split(separator: "\n").count)
    }

    static func delete(_ paths: [String]) async {
        await Task.detached {
            for p in paths { try? FileManager.default.removeItem(atPath: p) }
        }.value
    }

    static func freeBytes() -> Int64 {
        let v = try? URL(fileURLWithPath: home).resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(v?.volumeAvailableCapacity ?? 0)
    }

    static func cacheItems() async -> [CacheItem] {
        let store = await Shell.run(["pnpm", "store", "path"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        var items: [CacheItem] = []
        if !store.isEmpty {
            items.append(CacheItem(id: "pnpm-store", title: "pnpm store",
                                   detail: "Prune drops packages no project references any more. Run it after removing worktrees.",
                                   paths: [store], clear: .command(["pnpm", "store", "prune"])))
        }
        let pnpmCache = home + "/Library/Caches/pnpm"
        items.append(CacheItem(id: "pnpm-cache", title: "pnpm metadata cache",
                               detail: "Registry metadata. Re-fetched on the next install.",
                               paths: [pnpmCache], clear: .delete([pnpmCache])))
        let registry = [home + "/.cargo/registry/cache", home + "/.cargo/registry/src"]
        items.append(CacheItem(id: "cargo-registry", title: "Cargo registry",
                               detail: "Downloaded crate archives and sources. Re-downloaded on the next build.",
                               paths: registry, clear: .delete(registry)))
        let git = [home + "/.cargo/git/checkouts", home + "/.cargo/git/db"]
        items.append(CacheItem(id: "cargo-git", title: "Cargo git dependencies",
                               detail: "Git-sourced crates. Re-cloned on the next build.",
                               paths: git, clear: .delete(git)))
        func dir(_ id: String, _ title: String, _ detail: String, _ rel: [String]) {
            let paths = rel.map { home + "/" + $0 }
            items.append(CacheItem(id: id, title: title, detail: detail, paths: paths, clear: .delete(paths)))
        }
        dir("npm", "npm cache", "Downloaded package tarballs. Re-fetched on the next install.", [".npm/_cacache", ".npm/_npx"])
        dir("uv", "uv cache", "Python wheels and sources. Existing venvs keep working.", [".cache/uv"])
        dir("playwright", "Playwright browsers", "Downloaded browser builds. `playwright install` fetches them again.", ["Library/Caches/ms-playwright"])
        dir("huggingface", "Hugging Face models", "Downloaded models and datasets. Large to re-download.", [".cache/huggingface"])
        dir("bun", "bun cache", "Package cache. Re-fetched on the next install.", [".bun/install/cache"])
        dir("pip", "pip cache", "Downloaded wheels. Re-fetched on the next install.", ["Library/Caches/pip"])
        dir("typescript", "TypeScript type cache", "Editor auto-typings. Rebuilt on demand.", ["Library/Caches/typescript"])
        dir("node-gyp", "node-gyp headers", "Node headers for native builds. Re-downloaded on demand.", ["Library/Caches/node-gyp"])
        // Go marks module files read-only, so only `go clean` can delete them.
        items.append(CacheItem(id: "go", title: "Go modules and build cache",
                               detail: "Re-downloaded and rebuilt on the next go build.",
                               paths: [home + "/go/pkg/mod", home + "/Library/Caches/go-build"],
                               clear: .command(["go", "clean", "-modcache", "-cache"])))
        items.append(CacheItem(id: "brew", title: "Homebrew downloads",
                               detail: "Old bottles and installers. Installed formulae are untouched.",
                               paths: [home + "/Library/Caches/Homebrew"],
                               clear: .command(["brew", "cleanup", "--prune=all"])))
        let fm = FileManager.default
        return items.filter { $0.paths.contains { fm.fileExists(atPath: $0) } }
    }
}

enum AutoSweep {
    static let label = "com.sweeper.auto"
    private static let legacyLabel = "com.worktree-sweeper.auto"
    static var plistPath: String { Scanner.home + "/Library/LaunchAgents/\(label).plist" }
    static var logPath: String { Scanner.home + "/Library/Logs/Sweeper.log" }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    static func install() async -> Bool {
        guard let exe = Bundle.main.executablePath else { return false }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe, "--auto"],
            "StartCalendarInterval": ["Hour": 12, "Minute": 30],
            "ProcessType": "Background",
            "LowPriorityIO": true,
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return false }
        try? FileManager.default.createDirectory(atPath: (plistPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: plistPath, contents: data) else { return false }
        await Shell.run(["launchctl", "bootout", "gui/\(getuid())/\(label)"])
        return await Shell.run(["launchctl", "bootstrap", "gui/\(getuid())", plistPath]).ok
    }

    /// The agent stores the app's path, so re-register it on launch in case the app was moved or renamed.
    static func refreshIfInstalled() async {
        let legacy = Scanner.home + "/Library/LaunchAgents/\(legacyLabel).plist"
        let hadLegacy = FileManager.default.fileExists(atPath: legacy)
        if hadLegacy {
            await Shell.run(["launchctl", "bootout", "gui/\(getuid())/\(legacyLabel)"])
            try? FileManager.default.removeItem(atPath: legacy)
        }
        if hadLegacy || isInstalled { _ = await install() }
    }

    static func uninstall() async {
        await Shell.run(["launchctl", "bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(atPath: plistPath)
    }

    static func run() async {
        let before = Scanner.freeBytes()
        let rows = await Scanner.measureAll(await Scanner.baseRows(), await Scanner.processes())
        var lines = ["--- \(Date())"]
        var trash: [String] = []
        for w in rows where w.isSweepable {
            let r = await Scanner.remove(w)
            if let t = r.trash { trash.append(t) }
            lines.append(r.err.isEmpty ? "removed \(w.path) (\(w.staleReason ?? ""), \(formatKB(w.totalKB ?? 0)))" : "failed \(w.path): \(r.err)")
        }
        await Scanner.purge(trash)
        for w in rows where !w.isSweepable && !w.running && w.rustKB > 0 && (w.idleDays ?? 0) >= Rules.rustIdleDays {
            await Scanner.delete(w.rustPaths)
            lines.append("rust target \(w.path) (\(formatKB(w.rustKB)))")
        }
        await Shell.run(["pnpm", "store", "prune"])
        let freed = max(0, Scanner.freeBytes() - before)
        lines.append("freed \(formatBytes(freed))\n")
        let text = lines.joined(separator: "\n") + "\n"
        if let h = FileHandle(forWritingAtPath: logPath) {
            h.seekToEndOfFile()
            h.write(Data(text.utf8))
            try? h.close()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: Data(text.utf8))
        }
        if freed > 0 {
            await Shell.run(["osascript", "-e", "display notification \"Freed \(formatBytes(freed))\" with title \"Sweeper\""])
        }
    }
}
