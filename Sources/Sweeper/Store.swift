import SwiftUI

@MainActor
final class Store: ObservableObject {
    @Published var rows: [Worktree] = []
    @Published var caches: [CacheItem] = []
    @Published var scanning = false
    @Published var measured = 0
    @Published var busy: Set<String> = []
    @Published var free = Scanner.freeBytes()
    @Published var toast: String?
    @Published var autoSweep = AutoSweep.isInstalled

    init() {
        Task { await AutoSweep.refreshIfInstalled(); autoSweep = AutoSweep.isInstalled }
        Task.detached { await Scanner.purgeLeftovers() }
    }

    var sweepable: [Worktree] { rows.filter(\.isSweepable) }
    var rustKB: Int { rows.reduce(0) { $0 + $1.rustKB } }
    var rustIdle: [Worktree] { rows.filter { !$0.running && $0.rustKB > 0 } }

    func refresh() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        measured = 0
        let base = await Scanner.baseRows()
        rows = base
        let procs = await Scanner.processes()
        async let cacheList = Scanner.cacheItems()
        _ = await Scanner.measureAll(base, procs) { w in
            await MainActor.run {
                if let i = self.rows.firstIndex(where: { $0.id == w.id }) { self.rows[i] = w }
                self.measured += 1
            }
        }
        // Worktrees nested inside their main checkout (e.g. .worktrees/) are their own rows; don't count them twice.
        for i in rows.indices where rows[i].isMain {
            let main = rows[i]
            let nested = rows.filter { !$0.isMain && $0.path.hasPrefix(main.path + "/") }.compactMap(\.totalKB).reduce(0, +)
            rows[i].totalKB = main.totalKB.map { max(0, $0 - nested) }
        }
        caches = await cacheList
        for i in caches.indices {
            caches[i].kb = await Scanner.du(caches[i].paths.filter { FileManager.default.fileExists(atPath: $0) })
        }
        withAnimation(.snappy) { caches.sort { ($0.kb ?? 0) > ($1.kb ?? 0) } }
        free = Scanner.freeBytes()
    }

    /// `onlyIfSafe` re-checks right before deleting, so a commit made since the scan is never lost.
    func remove(_ targets: [Worktree], onlyIfSafe: Bool) async {
        let procs = await Scanner.processes()
        let mine = targets.filter { !busy.contains($0.id) }
        mine.forEach { busy.insert($0.id) }
        var trash: [String] = [], failed: [String] = [], skipped = 0, removedKB = 0
        // Linked worktrees before their main checkout, so git can still unregister them.
        for w in mine.sorted(by: { !$0.isMain && $1.isMain }) {
            let fresh = await Scanner.safety(w, procs)
            if onlyIfSafe && !fresh.isSweepable {
                skipped += 1
                if let i = rows.firstIndex(where: { $0.id == w.id }) { rows[i] = fresh }
                busy.remove(w.id)
                continue
            }
            let r = await Scanner.remove(fresh)
            if r.err.isEmpty {
                if let t = r.trash { trash.append(t) }
                removedKB += w.totalKB ?? 0
                withAnimation(.snappy) { rows.removeAll { $0.id == w.id || (w.isMain && $0.repo == w.repo) } }
            } else {
                failed.append("\(w.name): \(r.err)")
            }
            busy.remove(w.id)
        }
        var notes: [String] = []
        if skipped > 0 { notes.append("skipped \(skipped) that gained work since the scan") }
        if !failed.isEmpty { notes.append("failed: " + failed.joined(separator: "; ")) }
        let removed = mine.count - skipped - failed.count
        show((["Removed \(removed) · freeing \(formatKB(removedKB)) in the background"] + notes).joined(separator: " · "))
        let before = Scanner.freeBytes()
        await Scanner.purge(trash)
        if !trash.isEmpty { report(before, note: notes.joined(separator: " · ")) }
    }

    func slim(_ targets: [Worktree], rustOnly: Bool) async {
        let before = Scanner.freeBytes()
        let procs = await Scanner.processes()
        for w in targets {
            busy.insert(w.id)
            await Scanner.delete(rustOnly ? w.rustPaths : w.rustPaths + w.nodePaths)
            let fresh = await Scanner.measure(w, procs)
            if let i = rows.firstIndex(where: { $0.id == w.id }) { rows[i] = fresh }
            busy.remove(w.id)
        }
        report(before)
    }

    func clear(_ cache: CacheItem) async {
        let before = Scanner.freeBytes()
        busy.insert(cache.id)
        switch cache.clear {
        case .delete(let paths): await Scanner.delete(paths)
        case .command(let args): await Shell.run(args)
        }
        if let i = caches.firstIndex(where: { $0.id == cache.id }) {
            caches[i].kb = await Scanner.du(cache.paths.filter { FileManager.default.fileExists(atPath: $0) })
        }
        busy.remove(cache.id)
        report(before)
    }

    func setAutoSweep(_ on: Bool) async {
        if on { autoSweep = await AutoSweep.install() } else { await AutoSweep.uninstall(); autoSweep = false }
    }

    private func report(_ before: Int64, note: String = "") {
        free = Scanner.freeBytes()
        show("Freed \(formatBytes(max(0, free - before)))" + (note.isEmpty ? "" : " · " + note))
    }

    private func show(_ text: String) {
        withAnimation(.snappy) { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(text.contains("failed") ? 15 : 6))
            withAnimation(.snappy) { if self.toast == text { self.toast = nil } }
        }
    }
}
