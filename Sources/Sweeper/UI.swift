import SwiftUI

struct SweeperApp: App {
    var body: some Scene {
        WindowGroup("Sweeper") {
            ContentView().frame(minWidth: 1000, minHeight: 620)
        }
        .defaultSize(width: 1180, height: 760)
    }
}

enum Tab: String, CaseIterable { case worktrees = "Worktrees", caches = "Caches", disk = "Disk" }
enum Filter: String, CaseIterable { case all = "All", stale = "Stale", blocked = "Blocked" }

struct Confirm: Identifiable {
    enum Kind { case sweep, remove, slim }
    let id = UUID()
    let kind: Kind
    let rows: [Worktree]
}

struct ContentView: View {
    @StateObject private var store = Store()
    @StateObject private var disk = Disk()
    @State private var tab = Tab.worktrees
    @State private var filter = Filter.all
    @State private var sort = [KeyPathComparator(\Worktree.sizeKey, order: .reverse)]
    @State private var selection = Set<String>()
    @State private var confirm: Confirm?
    @State private var cacheToClear: CacheItem?

    var body: some View {
        VStack(spacing: 0) {
            Hero(store: store) { confirm = Confirm(kind: .sweep, rows: store.sweepable) }
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 14)
            switch tab {
            case .worktrees: worktrees
            case .caches: CachesView(store: store, cacheToClear: $cacheToClear)
            case .disk: DiskView(disk: disk) { store.free = Scanner.freeBytes() }
            }
        }
        .background(.background)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented).frame(width: 300)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: Binding(get: { store.autoSweep }, set: { on in Task { await store.setAutoSweep(on) } })) {
                    Label("Auto-sweep daily", systemImage: "clock.arrow.circlepath")
                }
                .toggleStyle(.button)
                .help("Every day at 12:30: remove stale worktrees that are safe, drop Rust targets idle \(Rules.rustIdleDays)+ days, prune the pnpm store. Log: ~/Library/Logs/Sweeper.log")
                Button { Task { await store.refresh() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .disabled(store.scanning)
                    .keyboardShortcut("r")
            }
        }
        .task { await store.refresh() }
        .sheet(item: $confirm) { c in ConfirmSheet(confirm: c) { act(c) } }
        .alert(item: $cacheToClear) { c in
            Alert(title: Text("Clear \(c.title)?"), message: Text(c.detail),
                  primaryButton: .destructive(Text("Clear")) { Task { await store.clear(c) } },
                  secondaryButton: .cancel())
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var visible: [Worktree] {
        store.rows.filter {
            switch filter {
            case .all: true
            case .stale: $0.staleReason != nil
            case .blocked: $0.loaded && !$0.blockers.isEmpty
            }
        }.sorted(using: sort)
    }

    private var maxKB: Int { max(1, store.rows.map(\.sizeKey).max() ?? 1) }

    private var worktrees: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $filter) { ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                Button("Select stale") { selection = Set(visible.filter { $0.staleReason != nil }.map(\.id)) }
                Button("Select all") { selection = Set(visible.map(\.id)) }
                if !selection.isEmpty {
                    Button("Clear selection") { selection.removeAll() }
                    let kb = store.rows.filter { selection.contains($0.id) }.compactMap(\.totalKB).reduce(0, +)
                    Text("\(selection.count) selected · \(formatKB(kb))").foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if !selection.isEmpty {
                    let picked = store.rows.filter { selection.contains($0.id) }
                    Button("Slim \(picked.count)") { confirm = Confirm(kind: .slim, rows: picked) }
                    Button("Remove \(picked.count)", role: .destructive) { confirm = Confirm(kind: .remove, rows: withDependents(picked)) }
                        .buttonStyle(.borderedProminent).tint(.red)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 10)

            Table(visible, selection: $selection, sortOrder: $sort) {
                TableColumn("") { w in
                    Toggle("", isOn: Binding(
                        get: { selection.contains(w.id) },
                        set: { on in if on { selection.insert(w.id) } else { selection.remove(w.id) } }
                    ))
                    .toggleStyle(.checkbox).labelsHidden()
                }
                .width(22)
                TableColumn("Worktree", value: \.name) { w in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.name).fontWeight(.medium)
                        Text(w.branch ?? "detached at \(w.head.prefix(7))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 4)
                }
                .width(min: 200, ideal: 260)
                TableColumn("PR", value: \.prKey) { w in PRPill(pr: w.pr) }
                    .width(110)
                TableColumn("Last used", value: \.lastUsedKey) { w in
                    Text(lastUsed(w)).foregroundStyle((w.idleDays ?? 0) >= Rules.idleDays ? .orange : .primary)
                        .monospacedDigit()
                }
                .width(90)
                TableColumn("Size", value: \.sizeKey) { w in SizeBar(w: w, maxKB: maxKB) }
                    .width(min: 180, ideal: 240)
                TableColumn("Status") { w in StatusView(w: w, busy: store.busy.contains(w.id)) }
                    .width(min: 160, ideal: 220)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .contextMenu(forSelectionType: String.self) { ids in
                let picked = store.rows.filter { ids.contains($0.id) }
                if let w = picked.first, picked.count == 1 {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.path)]) }
                    if let pr = w.pr, let url = URL(string: pr.url) { Button("Open PR #" + String(pr.number)) { NSWorkspace.shared.open(url) } }
                    Button("Copy path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(w.path, forType: .string)
                    }
                    Divider()
                }
                Button("Slim (delete node_modules + Rust target)") { confirm = Confirm(kind: .slim, rows: picked) }
                    .disabled(!picked.contains { $0.nodeKB + $0.rustKB > 0 })
                Button(picked.contains(where: \.isMain) ? "Delete repo…" : "Remove worktree…", role: .destructive) {
                    confirm = Confirm(kind: .remove, rows: withDependents(picked))
                }
            } primaryAction: { ids in
                for w in store.rows where ids.contains(w.id) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.path)])
                }
            }
        }
    }

    /// Deleting a main checkout deletes its repo, which takes every linked worktree with it.
    private func withDependents(_ picked: [Worktree]) -> [Worktree] {
        let repos = Set(picked.filter(\.isMain).map(\.repo))
        return picked + store.rows.filter { repos.contains($0.repo) && !picked.contains($0) }
    }

    private func lastUsed(_ w: Worktree) -> String {
        guard let d = w.idleDays else { return "–" }
        switch d {
        case 0: return "today"
        case 1: return "yesterday"
        case ..<60: return "\(d)d ago"
        default: return "\(d / 30)mo ago"
        }
    }

    private func act(_ c: Confirm) {
        selection.removeAll()
        Task {
            switch c.kind {
            case .sweep: await store.remove(c.rows, onlyIfSafe: true)
            case .remove: await store.remove(c.rows, onlyIfSafe: false)
            case .slim: await store.slim(c.rows, rustOnly: false)
            }
        }
    }
}

struct Hero: View {
    @ObservedObject var store: Store
    let sweep: () -> Void

    var body: some View {
        let stale = store.sweepable
        let staleKB = stale.compactMap(\.totalKB).reduce(0, +)
        let totalKB = store.rows.compactMap(\.totalKB).reduce(0, +)
        HStack(alignment: .center, spacing: 28) {
            Stat(label: "Free on disk", value: formatBytes(store.free), tint: store.free < 20_000_000_000 ? .red : .primary)
            Stat(label: "\(store.rows.count) worktrees", value: formatKB(totalKB))
            Stat(label: "Rust targets", value: formatKB(store.rustKB))
            Spacer()
            if store.scanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(store.rows.isEmpty ? "Finding worktrees…" : "Measuring \(store.measured) of \(store.rows.count)")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if stale.isEmpty {
                Label(store.scanning ? "Scanning" : "Nothing stale", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
            } else {
                Button(action: sweep) {
                    VStack(spacing: 1) {
                        Text("Clear \(stale.count) stale").font(.headline)
                        Text(formatKB(staleKB)).font(.caption).opacity(0.85)
                    }
                    .frame(minWidth: 150).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(.accentColor)
                .help("Merged or closed PR, or idle \(Rules.idleDays)+ days - and clean, fully pushed, not in use")
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.snappy, value: stale.count)
    }
}

struct Stat: View {
    let label: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(tint)
                .monospacedDigit().contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PRPill: View {
    let pr: PR?

    var body: some View {
        if let pr {
            let color: Color = switch pr.state {
            case "MERGED": .purple
            case "OPEN": .green
            default: .secondary
            }
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                if let url = URL(string: pr.url) {
                    Link(destination: url) {
                        HStack(spacing: 2) {
                            Text("#" + String(pr.number)).monospacedDigit().underline()
                            Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold))
                        }
                    }
                    .foregroundStyle(Color.accentColor)
                    .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                }
                Text(pr.state.lowercased()).foregroundStyle(.secondary)
            }
            .font(.caption)
            .help(pr.title)
        } else {
            Text("no PR").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

struct SizeBar: View {
    let w: Worktree
    let maxKB: Int

    var body: some View {
        if let total = w.totalKB {
            HStack(spacing: 10) {
                GeometryReader { geo in
                    let width = geo.size.width * CGFloat(total) / CGFloat(maxKB)
                    let junk = CGFloat(w.nodeKB + w.rustKB) / CGFloat(max(total, 1))
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(Color.accentColor.opacity(0.35)).frame(width: width)
                        Capsule().fill(Color.accentColor).frame(width: width * (1 - junk))
                    }
                }
                .frame(height: 6)
                Text(formatKB(total)).font(.callout.weight(.medium)).monospacedDigit().frame(width: 64, alignment: .trailing)
            }
            .help("node_modules \(formatKB(w.nodeKB)) · Rust target \(formatKB(w.rustKB)) · source \(formatKB(total - w.nodeKB - w.rustKB))")
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

struct StatusView: View {
    let w: Worktree
    let busy: Bool

    var body: some View {
        HStack(spacing: 4) {
            if busy {
                ProgressView().controlSize(.small)
                Text("Working…").font(.caption).foregroundStyle(.secondary)
            } else if !w.loaded {
                Text("–").foregroundStyle(.tertiary)
            } else if w.isSweepable {
                Badge(text: "safe · \(w.staleReason ?? "")", color: .green)
            } else if w.blockers.isEmpty {
                Badge(text: "active", color: .secondary)
            } else {
                ForEach(w.blockers.prefix(2), id: \.self) { Badge(text: $0, color: $0 == "main checkout" ? .blue : .orange) }
            }
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text).font(.caption.weight(.medium)).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct ConfirmSheet: View {
    let confirm: Confirm
    let go: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var understood = false
    @State private var loss: [String: (commits: Int, stashes: Int)] = [:]

    private var rows: [Worktree] { confirm.rows }
    private var repos: [Worktree] { confirm.kind == .remove ? rows.filter(\.isMain) : [] }

    private var kb: Int {
        confirm.kind == .slim ? rows.reduce(0) { $0 + $1.nodeKB + $1.rustKB } : rows.compactMap(\.totalKB).reduce(0, +)
    }

    private var inUse: [Worktree] { confirm.kind == .sweep ? [] : rows.filter(\.running) }

    private var losing: [Worktree] { confirm.kind == .remove ? rows.filter { !$0.isSafe } : [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary)
            List(rows) { w in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(w.name).fontWeight(.medium)
                        Text(w.staleReason ?? w.branch ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if confirm.kind == .remove && !w.isSafe {
                        Badge(text: w.blockers.joined(separator: ", "), color: .red)
                    }
                    Text(formatKB(confirm.kind == .slim ? w.nodeKB + w.rustKB : w.totalKB ?? 0)).monospacedDigit()
                }
            }
            .frame(minHeight: 220)
            if !inUse.isEmpty {
                Label("\(inUse.count) in use. Whatever runs there - dev server, terminal, editor, the desktop app - will break.", systemImage: "bolt.trianglebadge.exclamationmark.fill")
                    .foregroundStyle(.orange)
            }
            if !losing.isEmpty {
                Label("\(losing.count) of these have uncommitted or unpushed work. It will be lost.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            if !repos.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(repos) { r in
                        let l = loss[r.repo]
                        let linked = rows.filter { $0.repo == r.repo && !$0.isMain }.count
                        Label("Deletes the whole \(r.name) repo: its git history, \(linked) linked worktrees, "
                              + (l.map { "\($0.commits) commits no remote has, \($0.stashes) stashes." } ?? "checking local-only work…"),
                              systemImage: "xmark.octagon.fill")
                    }
                    Toggle("I understand this deletes the repo and cannot be undone", isOn: $understood)
                }
                .foregroundStyle(.red)
                .padding(12)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .task {
                    for r in repos { loss[r.repo] = await Scanner.repoLoss(r.repo) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action: { dismiss(); go() }) { Text(button) }
                    .buttonStyle(.borderedProminent)
                    .tint(confirm.kind == .slim ? .accentColor : .red)
                    .disabled(rows.isEmpty || (!repos.isEmpty && !understood))
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private var title: String {
        switch confirm.kind {
        case .sweep: "Clear \(rows.count) stale worktrees?"
        case .remove: repos.isEmpty ? "Remove \(rows.count) worktrees?" : "Delete \(repos.count) repo and \(rows.count - repos.count) worktrees?"
        case .slim: "Slim \(rows.count) worktrees?"
        }
    }

    private var subtitle: String {
        switch confirm.kind {
        case .sweep: "Each one is re-checked right before deletion. Anything that gained a commit or a process since the scan is skipped. Branches are kept."
        case .remove: "Deletes the directories permanently. Branches are kept."
        case .slim: "Deletes node_modules and Rust target dirs. The worktree stays; the next install or build restores them."
        }
    }

    private var button: String {
        switch confirm.kind {
        case .slim: "Slim · \(formatKB(kb))"
        default: "Delete · \(formatKB(kb))"
        }
    }
}

struct CachesView: View {
    @ObservedObject var store: Store
    @Binding var cacheToClear: CacheItem?

    var body: some View {
        List {
            Section("Build output in worktrees") {
                HStack {
                    CacheText(title: "Rust targets", detail: "cargo target dirs across \(store.rustIdle.count) worktrees not in use. Rebuilt on the next cargo build.")
                    Spacer()
                    Size(kb: store.rustIdle.reduce(0) { $0 + $1.rustKB })
                    Button("Clear") { Task { await store.slim(store.rustIdle, rustOnly: true) } }
                        .disabled(store.rustIdle.isEmpty || store.scanning)
                }
            }
            Section("Shared caches · \(formatKB(store.caches.compactMap(\.kb).reduce(0, +)))") {
                ForEach(store.caches) { c in
                    HStack {
                        CacheText(title: c.title, detail: c.detail)
                        Spacer()
                        if store.busy.contains(c.id) { ProgressView().controlSize(.small) }
                        else if let kb = c.kb { Size(kb: kb) } else { ProgressView().controlSize(.small) }
                        Button(c.id == "pnpm-store" ? "Prune" : "Clear") { cacheToClear = c }
                            .disabled(store.busy.contains(c.id))
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

struct CacheText: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.medium)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct Size: View {
    let kb: Int

    var body: some View {
        Text(formatKB(kb)).font(.callout.weight(.medium)).monospacedDigit().frame(width: 80, alignment: .trailing)
    }
}
