import SwiftUI

struct DiskEntry: Identifiable, Hashable {
    var id: String { path }
    let path: String
    var kb: Int
    let isDir: Bool
    var locked = false
    var name: String { (path as NSString).lastPathComponent }
}

/// macOS prompts per folder for these unless the app has Full Disk Access, so without it they are never read.
enum Privacy {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    static let homeFolders = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"].map { Scanner.home + "/" + $0 }
    /// Other apps' sandboxes, which trigger the "access data from other apps" prompt.
    static let duExclusions = ["-I", "Containers", "-I", "Group Containers"]

    static var hasFullDiskAccess: Bool {
        FileManager.default.isReadableFile(atPath: Scanner.home + "/Library/Application Support/com.apple.TCC/TCC.db")
    }
}

extension Scanner {
    // ponytail: files over 500 MB only, lower the bar if smaller files matter
    static func largeFiles(fullAccess: Bool) async -> [DiskEntry] {
        var skip = ["-name", "node_modules", "-o", "-name", ".git"]
        if !fullAccess {
            skip += ["-o", "-name", "Containers", "-o", "-name", "Group Containers"]
            for p in Privacy.homeFolders { skip += ["-o", "-path", p] }
        }
        let out = await Shell.run(["find", "-x", home, "("] + skip + [")", "-prune",
                                   "-o", "-type", "f", "-size", "+500M", "-print"]).out
        return out.split(separator: "\n").compactMap { line -> DiskEntry? in
            let url = URL(fileURLWithPath: String(line))
            guard let size = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize else { return nil }
            return DiskEntry(path: url.path, kb: size / 1024, isDir: false)
        }
        .sorted { $0.kb > $1.kb }
    }
}

@MainActor
final class Disk: ObservableObject {
    @Published var path = Scanner.home
    @Published var children: [String: [DiskEntry]] = [:]
    @Published var totals: [String: Int] = [:]
    @Published var loading: Set<String> = []
    @Published var largeFiles: [DiskEntry]?
    @Published var findingLarge = false
    @Published var fullAccess = Privacy.hasFullDiskAccess

    /// Called when the app comes back to the front, e.g. after granting access in System Settings.
    func recheckAccess() {
        let now = Privacy.hasFullDiskAccess
        guard now != fullAccess else { return }
        fullAccess = now
        children = [:]
        totals = [:]
        largeFiles = nil
        Task { await load(path) }
    }

    /// Deleting any of these breaks the account or the machine, not just frees space.
    private static let protected: Set<String> = {
        let h = Scanner.home
        return [h, "/Applications", h + "/Library", h + "/Applications", h + "/.ssh", h + "/.gnupg",
                h + "/.aws", h + "/.config", h + "/.kube", h + "/.docker", h + "/.cargo", h + "/.rustup"]
    }()

    func canDelete(_ e: DiskEntry) -> Bool {
        !Self.protected.contains(e.path) && (e.path.hasPrefix(Scanner.home + "/") || e.path.hasPrefix("/Applications/"))
    }

    func open(_ path: String) async {
        withAnimation(.snappy) { self.path = path }
        if children[path] == nil { await load(path) }
    }

    /// Measures each child separately so rows appear as they finish, instead of after one du over everything.
    func load(_ path: String) async {
        guard !loading.contains(path) else { return }
        loading.insert(path)
        defer { loading.remove(path) }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys)) ?? []
        var entries: [DiskEntry] = []
        var dirs: [String] = path == Scanner.home ? ["/Applications"] : []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
            if !fullAccess && Privacy.homeFolders.contains(url.path) {
                entries.append(DiskEntry(path: url.path, kb: 0, isDir: true, locked: true))
                continue
            }
            if v.isDirectory == true { dirs.append(url.path) }
            else if let size = v.totalFileAllocatedSize, size > 0 { entries.append(DiskEntry(path: url.path, kb: size / 1024, isDir: false)) }
        }
        publish(path, entries)
        let flags = fullAccess ? ["-x"] : ["-x"] + Privacy.duExclusions
        await withTaskGroup(of: DiskEntry.self) { group in
            var pending = dirs[...]
            for _ in 0..<8 {
                if let d = pending.popFirst() { group.addTask { DiskEntry(path: d, kb: await Scanner.du(flags + [d]), isDir: true) } }
            }
            for await e in group {
                if e.kb > 0 { entries.append(e) }
                publish(path, entries)
                if let d = pending.popFirst() { group.addTask { DiskEntry(path: d, kb: await Scanner.du(flags + [d]), isDir: true) } }
            }
        }
    }

    private func publish(_ path: String, _ entries: [DiskEntry]) {
        withAnimation(.snappy) {
            children[path] = entries.sorted { ($0.locked ? -1 : $0.kb) > ($1.locked ? -1 : $1.kb) }
            totals[path] = entries.reduce(0) { $0 + $1.kb }
        }
    }

    func findLarge() async {
        findingLarge = true
        largeFiles = await Scanner.largeFiles(fullAccess: fullAccess)
        findingLarge = false
    }

    func remove(_ e: DiskEntry, permanent: Bool) async -> String? {
        guard canDelete(e) else { return "\(e.name) is protected." }
        let url = URL(fileURLWithPath: e.path)
        let error: String? = await Task.detached {
            do {
                if permanent { try FileManager.default.removeItem(at: url) }
                else { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                return nil
            } catch { return error.localizedDescription }
        }.value
        if error != nil { return error }
        withAnimation(.snappy) {
            for key in children.keys {
                children[key]?.removeAll { $0.path == e.path }
                for i in children[key]?.indices ?? 0..<0 where e.path.hasPrefix(children[key]![i].path + "/") {
                    children[key]![i].kb -= e.kb
                }
                if e.path.hasPrefix(key + "/") { totals[key, default: 0] -= e.kb }
            }
            largeFiles?.removeAll { $0.path == e.path || $0.path.hasPrefix(e.path + "/") }
        }
        return nil
    }
}

struct DiskView: View {
    enum Mode: String, CaseIterable { case folders = "Folders", large = "Large files" }

    @ObservedObject var disk: Disk
    let onFreed: () -> Void
    @State private var mode = Mode.folders
    @State private var pending: DiskEntry?
    @State private var error: String?

    private var entries: [DiskEntry] {
        mode == .folders ? disk.children[disk.path] ?? [] : disk.largeFiles ?? []
    }

    private var busy: Bool { mode == .folders ? disk.loading.contains(disk.path) : disk.findingLarge }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                if mode == .folders { breadcrumb }
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                    Text(mode == .folders ? "Measuring… big folders take a minute" : "Searching for files over 500 MB…")
                        .font(.callout).foregroundStyle(.secondary)
                } else if mode == .folders, let total = disk.totals[disk.path] {
                    Text(formatKB(total)).font(.callout.weight(.semibold)).monospacedDigit()
                }
                Button("Empty Trash") {
                    Task {
                        await Shell.run(["osascript", "-e", "tell application \"Finder\" to empty trash"])
                        onFreed()
                    }
                }
                Button {
                    Task {
                        if mode == .folders { disk.children[disk.path] = nil; await disk.load(disk.path) }
                        else { await disk.findLarge() }
                    }
                } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(busy)
                    .help("Measure again")
            }
            .padding(.horizontal, 20).padding(.bottom, 10)

            if !disk.fullAccess {
                HStack(spacing: 12) {
                    Image(systemName: "lock.shield").font(.title2).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Grant Full Disk Access once").fontWeight(.semibold)
                        Text("In Full Disk Access, click + and pick Sweeper, or drag it in from Finder. Then quit and reopen Sweeper. This lets it measure Desktop, Documents, Downloads, Movies, Music, Pictures and app data without a prompt per folder.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show Sweeper in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                    Button("Open System Settings") { NSWorkspace.shared.open(Privacy.settingsURL) }
                        .buttonStyle(.borderedProminent)
                }
                .padding(14)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 20).padding(.bottom, 10)
            }

            if entries.isEmpty && busy {
                VStack { Spacer(); ProgressView(); Spacer() }.frame(maxWidth: .infinity)
            } else {
                List(entries) { e in
                    DiskRow(e: e, maxKB: entries.first?.kb ?? 1, showPath: mode == .large, deletable: disk.canDelete(e)) {
                        pending = e
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if e.locked { NSWorkspace.shared.open(Privacy.settingsURL) }
                        else if e.isDir { Task { await disk.open(e.path) } }
                    }
                    .contextMenu {
                        Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: e.path)) }
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: e.path)]) }
                        Divider()
                        Button("Delete…", role: .destructive) { pending = e }.disabled(!disk.canDelete(e))
                    }
                }
                .listStyle(.inset)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            disk.recheckAccess()
        }
        .task(id: mode) {
            if mode == .folders { if disk.children[disk.path] == nil { await disk.load(disk.path) } }
            else if disk.largeFiles == nil { await disk.findLarge() }
        }
        .confirmationDialog("Delete \(pending?.name ?? "")?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            presenting: pending) { e in
            Button("Move to Trash · \(formatKB(e.kb))") { delete(e, permanent: false) }
            Button("Delete permanently · \(formatKB(e.kb))", role: .destructive) { delete(e, permanent: true) }
        } message: { e in
            Text("\(e.path)\n\nTrash keeps it recoverable, but the space only frees once you empty Trash.")
        }
        .alert("Could not delete", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: { Text(error ?? "") }
    }

    private func delete(_ e: DiskEntry, permanent: Bool) {
        Task {
            error = await disk.remove(e, permanent: permanent)
            onFreed()
        }
    }

    private var breadcrumb: some View {
        let home = Scanner.home
        let inHome = disk.path.hasPrefix(home)
        let rel = inHome ? String(disk.path.dropFirst(home.count)) : disk.path
        var crumbs: [(String, String)] = inHome ? [("Home", home)] : []
        var acc = inHome ? home : ""
        for part in rel.split(separator: "/") {
            acc += "/" + part
            crumbs.append((String(part), acc))
        }
        return HStack(spacing: 4) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { i, crumb in
                if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                Button(crumb.0) { Task { await disk.open(crumb.1) } }
                    .buttonStyle(.plain)
                    .fontWeight(i == crumbs.count - 1 ? .semibold : .regular)
                    .foregroundStyle(i == crumbs.count - 1 ? .primary : .secondary)
            }
            if !inHome {
                Button("Back to Home") { Task { await disk.open(home) } }.buttonStyle(.link).padding(.leading, 8)
            }
        }
        .lineLimit(1)
    }
}

struct DiskRow: View {
    let e: DiskEntry
    let maxKB: Int
    let showPath: Bool
    let deletable: Bool
    let onDelete: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: e.path))
                .resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.name).fontWeight(.medium).lineLimit(1)
                if showPath {
                    Text((e.path as NSString).deletingLastPathComponent.replacingOccurrences(of: Scanner.home, with: "~"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(minWidth: 220, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Color.accentColor.opacity(e.isDir ? 1 : 0.6))
                        .frame(width: max(3, geo.size.width * CGFloat(e.kb) / CGFloat(max(maxKB, 1))))
                }
            }
            .frame(height: 6)
            if e.locked {
                Label("Needs Full Disk Access", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                    .fixedSize()
            } else {
                Text(formatKB(e.kb)).font(.callout.weight(.medium)).monospacedDigit().frame(width: 80, alignment: .trailing)
            }
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .opacity(hover && deletable && !e.locked ? 1 : 0)
                .disabled(!deletable || e.locked)
                .help("Delete")
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).opacity(e.isDir ? 1 : 0)
        }
        .padding(.vertical, 3)
        .onHover { hover = $0 }
    }
}
