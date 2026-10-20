import Foundation
import Testing
import PiSwiftChord
import PiSwiftDurableTesting
@testable import PiSwiftDurable
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One ignore file: its patterns, and its directory relative to the work tree ("" at the top).
private struct ReferenceIgnoreFile {
    struct Pattern { var glob: String; var negated: Bool; var directoryOnly: Bool; var anchored: Bool }
    var base: String
    var patterns: [Pattern]

    static func load(_ path: String, base: String) -> Self? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var patterns: [Pattern] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let negated = line.hasPrefix("!")
            if negated { line.removeFirst() }
            let directoryOnly = line.hasSuffix("/")
            if directoryOnly { line.removeLast() }
            let anchored = line.contains("/")
            if line.hasPrefix("/") { line.removeFirst() }
            patterns.append(.init(glob: line, negated: negated, directoryOnly: directoryOnly, anchored: anchored))
        }
        return Self(base: base, patterns: patterns)
    }

    /// Later files and later patterns win, as in git.
    static func ignored(_ path: String, directory: Bool, _ files: [Self]) -> Bool {
        for file in files.reversed() {
            guard file.base.isEmpty || path.hasPrefix(file.base + "/") else { continue }
            let relative = file.base.isEmpty ? path : String(path.dropFirst(file.base.count + 1))
            let name = relative.split(separator: "/").last.map(String.init) ?? relative
            for pattern in file.patterns.reversed() where directory || !pattern.directoryOnly {
                let matched = pattern.anchored
                    ? fnmatch(pattern.glob, relative, FNM_PATHNAME) == 0 : fnmatch(pattern.glob, name, 0) == 0
                if matched { return !pattern.negated }
            }
        }
        return false
    }
}

private struct ReferenceWalk {
    let hidden: Bool
    let exclude: Set<String>
    let maxEntries: Int
    let maxBytes: Int
    let deadline: ContinuousClock.Instant
    let context: ChordContext
    let workTree: String?
    var entries: [FileListEntry] = []
    var bytes = 0
    var truncated = false
    var aborted = false

    func treeRelative(_ path: String) -> String {
        guard let workTree, path != workTree else { return "" }
        return String(path.dropFirst(workTree.count + 1))
    }

    mutating func walk(_ directory: String, _ relative: String, _ ignores: [ReferenceIgnoreFile]) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        var ignores = ignores
        if workTree != nil, let file = ReferenceIgnoreFile.load(directory + "/.gitignore", base: treeRelative(directory)) {
            ignores.append(file)
        }
        for name in names.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            if truncated || aborted { return }
            if name == ".git" || exclude.contains(name) || (!hidden && name.hasPrefix(".")) { continue }
            let child = directory + "/" + name
            var info = stat()
            guard lstat(child, &info) == 0 else { continue }
            let kind: FileKind
            switch info.st_mode & S_IFMT {
            case S_IFDIR: kind = .directory
            case S_IFREG: kind = .file
            case S_IFLNK: kind = .symlink
            default: continue
            }
            if workTree != nil, ReferenceIgnoreFile.ignored(treeRelative(child), directory: kind == .directory, ignores) { continue }
            if context.abortSignal?.aborted == true { aborted = true; return }
            let path = relative.isEmpty ? name : relative + "/" + name
            let cost = path.utf8.count + 2
            if entries.count >= maxEntries || bytes + cost > maxBytes || ContinuousClock.now >= deadline {
                truncated = true
                return
            }
            entries.append(.init(path: path, kind: kind))
            bytes += cost
            if kind == .directory { walk(child, path, ignores) }
        }
    }
}

/// A reference `listFiles` for the conformance cases, which upstream leaves to pi-env: a plain walk with a small
/// gitignore matcher (`!`, a leading or inner `/`, a trailing `/`, and fnmatch globs; no `**`, no escapes, and no
/// global excludes file).
func referenceListFiles(_ base: LocalExecutionEnv, _ path: String, options: ListFilesOptions?,
                        context: ChordContext) async -> Result<FileListing, FileError> {
    let maxEntries = options?.maxEntries ?? 50_000
    let maxBytes = min(options?.maxBytes ?? 4 << 20, 16_672_358)
    let timeout = options?.timeout ?? .seconds(10)
    guard maxEntries >= 0, maxBytes >= 0, timeout >= .zero else {
        return .failure(FileError(.invalid, message: "listFiles bounds must not be negative", path: path))
    }
    if context.abortSignal?.aborted == true { return .failure(FileError(.aborted, message: "listFiles aborted", path: path)) }
    let root: String
    switch await base.absolutePath(path, context: context) {
    case .success(let value): root = value
    case .failure(let error): return .failure(error)
    }
    var info = stat()
    guard stat(root, &info) == 0 else {
        return .failure(FileError(errno == ENOENT ? .notFound : .unknown, message: "Cannot list \(path)", path: path))
    }
    guard info.st_mode & S_IFMT == S_IFDIR else {
        return .failure(FileError(.notDirectory, message: "\(path) is not a directory", path: path))
    }
    var workTree: String?
    if options?.gitignore != false {
        var candidate = root
        while true {
            var gitInfo = stat()
            if lstat(candidate + "/.git", &gitInfo) == 0 { workTree = candidate; break }
            let parent = (candidate as NSString).deletingLastPathComponent
            if parent == candidate || parent.isEmpty { break }
            candidate = parent
        }
    }
    var walk = ReferenceWalk(hidden: options?.hidden ?? true, exclude: Set(options?.exclude ?? []),
                             maxEntries: maxEntries, maxBytes: maxBytes, deadline: .now.advanced(by: timeout),
                             context: context, workTree: workTree)
    var ignores: [ReferenceIgnoreFile] = []
    if let workTree {
        if let exclude = ReferenceIgnoreFile.load(workTree + "/.git/info/exclude", base: "") { ignores.append(exclude) }
        // The .gitignore files of the work tree down to the listed directory's parent; the walk reads its own.
        var directory = workTree
        for component in walk.treeRelative(root).split(separator: "/") {
            if let file = ReferenceIgnoreFile.load(directory + "/.gitignore", base: walk.treeRelative(directory)) {
                ignores.append(file)
            }
            directory += "/" + component
        }
    }
    walk.walk(root, "", ignores)
    if walk.aborted { return .failure(FileError(.aborted, message: "listFiles aborted", path: path)) }
    return .success(FileListing(entries: walk.entries, truncated: walk.truncated))
}

private func listingConformanceCases() -> [EnvConformanceCase] {
    envConformanceCases(capabilities: .init(exec: false, watch: false, listFiles: true), makeSymlink: { target, path, _ in
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
    }, withEnv: { use in
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-durable-list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = LocalExecutionEnv(cwd: directory.path)
        var env = ToolFixtureEnv(base: base)
        env.listFilesHook = { path, options, context in await referenceListFiles(base, path, options: options, context: context) }
        do {
            try await use(env)
            await env.cleanup(context: .background)
        } catch { await env.cleanup(context: .background); throw error }
    }).filter { $0.name.hasPrefix("listFiles") }
}

@Suite("ExecutionEnv.listFiles")
struct EnvListFilesTests {
    // upstream env-conformance.ts listFiles cases, against a reference listing.
    @Test("listFiles conformance", arguments: listingConformanceCases())
    func conformance(_ testCase: EnvConformanceCase) async throws { try await testCase.run() }

    @Test("selects four listFiles cases, and a fifth with symbolic links")
    func capabilitySelection() {
        let provider: @Sendable (@Sendable (any ExecutionEnv) async throws -> Void) async throws -> Void = { _ in }
        #expect(envConformanceCases(capabilities: .init(listFiles: true), withEnv: provider).count == 29)
        #expect(envConformanceCases(capabilities: .init(exec: false, symlinks: false, watch: false, listFiles: true),
                                    withEnv: provider).count == 12)
        #expect(listingConformanceCases().count == 5)
    }

    @Test("LocalExecutionEnv and FakeExecutionEnv do not list files")
    func notSupportedByDefault() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-durable-list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let envs: [any ExecutionEnv] = [LocalExecutionEnv(cwd: directory.path), FakeExecutionEnv()]
        for env in envs {
            let result = await env.listFiles(".", options: nil, context: .background)
            guard case .failure(let error) = result else { Issue.record("Expected notSupported; got \(result)"); continue }
            #expect(error.code == .notSupported)
            #expect(error.path == ".")
        }
    }
}
