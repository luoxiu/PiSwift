import PiSwiftDurable

extension EnvChecks {
    /// A listing as `<kind letter> <path>` lines (`f`, `d`, `l`), with its truncation.
    struct Listed: Equatable, CustomStringConvertible {
        var entries: [String]
        var truncated: Bool
        var description: String { "\(entries) truncated: \(truncated)" }
    }

    func listed(_ path: String, _ options: ListFilesOptions? = nil) async throws -> Listed {
        let listing = try await env.listFiles(path, options: options, context: Self.context).get()
        let letter: [FileKind: String] = [.file: "f", .directory: "d", .symlink: "l"]
        return Listed(entries: listing.entries.map { "\(letter[$0.kind]!) \($0.path)" }, truncated: listing.truncated)
    }

    func writeAll(_ files: [String]) async throws {
        for file in files { try await write(file, "") }
    }

    static func case25(_ h: Self) async throws {
        try await h.writeAll(["b.txt", "a/z.txt", "a/b/c.txt", ".hidden/x", "A.txt"])
        try await h.directory("empty")
        try EnvAssertions.equal(try await h.listed("."), Listed(entries: [
            "d .hidden", "f .hidden/x", "f A.txt", "d a", "d a/b", "f a/b/c.txt", "f a/z.txt", "f b.txt", "d empty",
        ], truncated: false))
        try EnvAssertions.equal(try await h.listed(".", .init(hidden: false)).entries, [
            "f A.txt", "d a", "d a/b", "f a/b/c.txt", "f a/z.txt", "f b.txt", "d empty",
        ])
        let expected = Listed(entries: ["d b", "f b/c.txt", "f z.txt"], truncated: false)
        try EnvAssertions.equal(try await h.listed("a"), expected)
        try EnvAssertions.equal(try await h.listed(try await h.env.absolutePath("a", context: context).get()), expected)
        try EnvAssertions.equal(try await h.listed("empty"), Listed(entries: [], truncated: false))
    }

    static func case26(_ h: Self) async throws {
        try await h.writeAll(["keep.txt", "out/x.js", "sub/keep.txt", "sub/drop.log", "node_modules/m/i.js"])
        try await h.write(".gitignore", "out/\n*.log\n")
        try await h.write("sub/.gitignore", "!keep.txt\n")
        // Not a work tree yet: `.gitignore` files have no effect.
        try EnvAssertions.ok(try await h.listed(".").entries.contains("f out/x.js"), "Expected out/x.js outside a work tree")
        try await h.write(".git/HEAD", "ref: refs/heads/main\n")
        try await h.write(".git/info/exclude", "keep.txt\n")
        try EnvAssertions.equal(try await h.listed(".", .init(exclude: ["node_modules"])).entries, [
            "f .gitignore", "d sub", "f sub/.gitignore", "f sub/keep.txt",
        ])
        // A directory inside the work tree applies its parents' rules.
        try EnvAssertions.equal(try await h.listed("sub").entries, ["f .gitignore", "f keep.txt"])
        let all = try await h.listed(".", .init(gitignore: false)).entries
        try EnvAssertions.ok(all.contains("f out/x.js") && all.contains("f node_modules/m/i.js") && all.contains("f keep.txt"),
                             "Expected ignored entries without gitignore; got \(all)")
        try EnvAssertions.ok(!all.contains { $0.contains(".git/") || $0 == "d .git" }, "Listed .git; got \(all)")
    }

    static func case27(_ h: Self) async throws {
        try await h.writeAll(["a", "b", "c"])
        try EnvAssertions.equal(try await h.listed(".", .init(maxEntries: 2)), Listed(entries: ["f a", "f b"], truncated: true))
        try EnvAssertions.equal(try await h.listed(".", .init(maxEntries: 3)), Listed(entries: ["f a", "f b", "f c"], truncated: false))
        // Each entry counts its path plus two bytes.
        try EnvAssertions.equal(try await h.listed(".", .init(maxBytes: 6)), Listed(entries: ["f a", "f b"], truncated: true))
        try EnvAssertions.equal(try await h.listed(".", .init(maxEntries: 0)), Listed(entries: [], truncated: true))
        try EnvAssertions.equal(code(await h.env.listFiles(".", options: .init(maxEntries: -1), context: context)), .invalid)
        // Upstream's fractional timeoutMs has no counterpart: a Duration may hold part of a millisecond.
        try EnvAssertions.equal(code(await h.env.listFiles(".", options: .init(timeout: .milliseconds(-1)), context: context)), .invalid)
    }

    static func case28(_ h: Self) async throws {
        try await h.write("file.txt", "")
        try EnvAssertions.equal(code(await h.env.listFiles("missing", options: nil, context: context)), .notFound)
        try EnvAssertions.equal(code(await h.env.listFiles("file.txt", options: nil, context: context)), .notDirectory)
        try EnvAssertions.equal(code(await h.env.listFiles(".", options: nil, context: abortedContext())), .aborted)
    }

    static func case29(_ h: Self) async throws {
        try await h.write("dir/inner.txt", "")
        try await h.link("dir", "link"); try await h.link("missing", "dangling"); try await h.link("..", "dir/loop")
        try EnvAssertions.equal(try await h.listed(".").entries, ["l dangling", "d dir", "f dir/inner.txt", "l dir/loop", "l link"])
        // The listed directory itself may be a link.
        try EnvAssertions.equal(try await h.listed("link").entries, ["f inner.txt", "l loop"])
    }
}
