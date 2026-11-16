//! 参照 (ref)。ブランチやタグの実体は、commit の ID を 1 行書いただけのファイル。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Repository = @import("Repository.zig");
const Oid = @import("Oid.zig");
const Commit = @import("Commit.zig");

pub const Error = error{ CorruptRef, RefLocked };

const max_ref_name = 1024;
const max_symref_depth = 5;

pub const Head = union(enum) {
    /// "ref: refs/heads/main"。ブランチの上にいる状態。名前は呼び出し側が free する
    symbolic: []const u8,
    /// commit を直接指している detached HEAD
    detached: Oid,

    pub fn deinit(self: Head, allocator: Allocator) void {
        switch (self) {
            .symbolic => |name| allocator.free(name),
            .detached => {},
        }
    }
};

pub fn readHead(allocator: Allocator, repo: Repository) !Head {
    var buf: [max_ref_name]u8 = undefined;
    const content = try repo.git_dir.readFile(repo.io, "HEAD", &buf);
    const line = std.mem.trim(u8, content, " \t\r\n");
    if (std.mem.startsWith(u8, line, "ref: ")) {
        return .{ .symbolic = try allocator.dupe(u8, line["ref: ".len..]) };
    }
    return .{ .detached = Oid.fromHex(line) catch return error.CorruptRef };
}

/// "refs/heads/main" を "main" にする。ブランチ以外の名前はそのまま返す
pub fn shortName(name: []const u8) []const u8 {
    const prefix = "refs/heads/";
    return if (std.mem.startsWith(u8, name, prefix)) name[prefix.len..] else name;
}

/// "refs/heads/main" や "HEAD" を commit の ID まで辿る。無ければ null
pub fn resolve(allocator: Allocator, repo: Repository, name: []const u8) !?Oid {
    return resolveDepth(allocator, repo, name, 0);
}

fn resolveDepth(
    allocator: Allocator,
    repo: Repository,
    name: []const u8,
    depth: usize,
) !?Oid {
    if (depth >= max_symref_depth) return error.CorruptRef;

    var buf: [max_ref_name]u8 = undefined;
    const content = repo.git_dir.readFile(repo.io, name, &buf) catch |err| switch (err) {
        // ファイルが無くても packed-refs に押し込まれているかもしれない。
        // 同じ名前のディレクトリ (refs/heads/feat/x がある feat など) も「無い」扱い
        error.FileNotFound, error.IsDir => return readPacked(allocator, repo, name),
        else => return err,
    };
    const line = std.mem.trim(u8, content, " \t\r\n");
    if (std.mem.startsWith(u8, line, "ref: ")) {
        return resolveDepth(allocator, repo, line["ref: ".len..], depth + 1);
    }
    return Oid.fromHex(line) catch error.CorruptRef;
}

/// 省略された名前を補って探す。"main" → "refs/heads/main" など。順番は git と同じ
pub fn lookup(allocator: Allocator, repo: Repository, name: []const u8) !?Oid {
    const patterns = [_][]const u8{
        "{s}",
        "refs/{s}",
        "refs/tags/{s}",
        "refs/heads/{s}",
        "refs/remotes/{s}",
        "refs/remotes/{s}/HEAD",
    };
    var buf: [max_ref_name]u8 = undefined;
    inline for (patterns) |pattern| {
        const full = std.fmt.bufPrint(&buf, pattern, .{name}) catch return null;
        if (try resolve(allocator, repo, full)) |oid| return oid;
    }
    return null;
}

/// `git pack-refs` がまとめた packed-refs から探す
fn readPacked(allocator: Allocator, repo: Repository, name: []const u8) !?Oid {
    const text = (try repo.readFile(allocator, "packed-refs")) orelse return null;
    defer allocator.free(text);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        // '#' はヘッダ、'^' は直前の tag が指す commit (peeled)
        if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        if (std.mem.eql(u8, line[space + 1 ..], name)) {
            return Oid.fromHex(line[0..space]) catch error.CorruptRef;
        }
    }
    return null;
}

pub const Reflog = struct {
    who: Commit.Signature,
    message: []const u8,
};

/// ref を `new` に書き換える。HEAD がブランチを指していれば、そのブランチを書き換える
pub fn update(
    allocator: Allocator,
    repo: Repository,
    name: []const u8,
    new: Oid,
    reflog: ?Reflog,
) !void {
    if (std.mem.eql(u8, name, "HEAD")) {
        const head = try readHead(allocator, repo);
        defer head.deinit(allocator);
        if (head == .symbolic) {
            // ブランチを進めて、HEAD 自身の reflog にも同じ行を残す
            const old = try resolve(allocator, repo, head.symbolic);
            try update(allocator, repo, head.symbolic, new, reflog);
            if (reflog) |log| try appendLog(allocator, repo, "HEAD", old, new, log);
            return;
        }
    }

    const old = try resolve(allocator, repo, name);
    try writeRef(repo, name, new);
    if (reflog) |log| try appendLog(allocator, repo, name, old, new, log);
}

/// lock ファイルに書いてから rename で差し替える。途中で死んでも中途半端な ref は残らない
fn writeRef(repo: Repository, name: []const u8, oid: Oid) !void {
    if (Dir.path.dirname(name)) |dir| try repo.git_dir.createDirPath(repo.io, dir);

    var lock_buf: [max_ref_name + 5]u8 = undefined;
    const lock = try std.fmt.bufPrint(&lock_buf, "{s}.lock", .{name});
    const created = repo.git_dir.createFile(repo.io, lock, .{ .exclusive = true });
    const file = created catch |err| switch (err) {
        error.PathAlreadyExists => return error.RefLocked,
        else => return err,
    };
    errdefer repo.git_dir.deleteFile(repo.io, lock) catch {};
    {
        defer file.close(repo.io);
        try file.writeStreamingAll(repo.io, &(oid.toHex() ++ "\n".*));
    }
    try repo.git_dir.rename(lock, repo.git_dir, name, repo.io);
}

/// logs/<name> に 1 行追記する。`git reflog` が読む
fn appendLog(
    allocator: Allocator,
    repo: Repository,
    name: []const u8,
    old: ?Oid,
    new: Oid,
    log: Reflog,
) !void {
    const path = try std.fmt.allocPrint(allocator, "logs/{s}", .{name});
    defer allocator.free(path);
    if (Dir.path.dirname(path)) |dir| try repo.git_dir.createDirPath(repo.io, dir);

    const zero = Oid.fromBytes(&@as([Oid.len]u8, @splat(0)));
    const line = try std.fmt.allocPrint(
        allocator,
        "{f} {f} {f}\t{s}\n",
        .{ old orelse zero, new, log.who, log.message },
    );
    defer allocator.free(line);

    const file = try repo.git_dir.createFile(repo.io, path, .{ .truncate = false });
    defer file.close(repo.io);
    const end = try file.length(repo.io);
    try file.writePositionalAll(repo.io, line, end);
}

pub const Ref = struct {
    name: []const u8,
    oid: Oid,
};

/// `prefix` (例: "refs/heads") 以下の ref を名前順に集める。loose と packed の両方を見る
pub fn list(allocator: Allocator, repo: Repository, prefix: []const u8) ![]Ref {
    var refs: std.ArrayList(Ref) = .empty;
    errdefer {
        for (refs.items) |r| allocator.free(r.name);
        refs.deinit(allocator);
    }

    if (repo.git_dir.openDir(repo.io, prefix, .{ .iterate = true })) |dir| {
        var d = dir;
        defer d.close(repo.io);
        var walker = try d.walk(allocator);
        defer walker.deinit();
        while (try walker.next(repo.io)) |entry| {
            if (entry.kind != .file or std.mem.endsWith(u8, entry.basename, ".lock")) continue;
            const name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.path });
            errdefer allocator.free(name);
            const oid = (try resolve(allocator, repo, name)) orelse {
                allocator.free(name);
                continue;
            };
            try refs.append(allocator, .{ .name = name, .oid = oid });
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    // packed-refs にしか無いものを足す
    if (try repo.readFile(allocator, "packed-refs")) |text| {
        defer allocator.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const name = line[space + 1 ..];
            if (!std.mem.startsWith(u8, name, prefix) or contains(refs.items, name)) continue;
            const oid = Oid.fromHex(line[0..space]) catch return error.CorruptRef;
            const copy = try allocator.dupe(u8, name);
            errdefer allocator.free(copy);
            try refs.append(allocator, .{ .name = copy, .oid = oid });
        }
    }

    std.mem.sort(Ref, refs.items, {}, byName);
    return refs.toOwnedSlice(allocator);
}

pub fn freeList(allocator: Allocator, refs: []const Ref) void {
    for (refs) |r| allocator.free(r.name);
    allocator.free(refs);
}

fn contains(refs: []const Ref, name: []const u8) bool {
    for (refs) |r| if (std.mem.eql(u8, r.name, name)) return true;
    return false;
}

fn byName(_: void, a: Ref, b: Ref) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

test "update, resolve, list and packed-refs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var repo = try Repository.initForTest(allocator, tmp);
    defer repo.close(allocator);

    const head = try readHead(allocator, repo);
    defer head.deinit(allocator);
    try std.testing.expectEqualStrings("refs/heads/main", head.symbolic);
    try std.testing.expectEqual(null, try resolve(allocator, repo, "HEAD"));

    const a = try Oid.fromHex("ce013625030ba8dba906f756967f9e9ca394464a");
    const b = try Oid.fromHex("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    const who = Commit.Signature{ .name = "T", .email = "t@example.com", .time = .{ .secs = 0, .offset_min = 0 } };
    try update(allocator, repo, "HEAD", a, .{ .who = who, .message = "first" });
    try std.testing.expect(a.eql((try resolve(allocator, repo, "refs/heads/main")).?));
    try std.testing.expect(a.eql((try lookup(allocator, repo, "main")).?));

    // HEAD 経由の更新は、ブランチと HEAD の両方の reflog に「前の値 → 新しい値」で残る
    try update(allocator, repo, "HEAD", b, .{ .who = who, .message = "second" });
    const log = try repo.git_dir.readFileAlloc(io, "logs/HEAD", allocator, .limited(1 << 16));
    defer allocator.free(log);
    try std.testing.expectEqualStrings(
        "0000000000000000000000000000000000000000 ce013625030ba8dba906f756967f9e9ca394464a T <t@example.com> 0 +0000\tfirst\n" ++
            "ce013625030ba8dba906f756967f9e9ca394464a e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 T <t@example.com> 0 +0000\tsecond\n",
        log,
    );
    try update(allocator, repo, "HEAD", a, null);

    try repo.git_dir.writeFile(io, .{ .sub_path = "packed-refs", .data = "# pack-refs with: peeled fully-peeled sorted \n" ++
        "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 refs/heads/old\n" ++
        "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 refs/tags/v1\n" });
    try std.testing.expect(b.eql((try lookup(allocator, repo, "v1")).?));

    const refs = try list(allocator, repo, "refs/heads");
    defer freeList(allocator, refs);
    try std.testing.expectEqual(2, refs.len);
    try std.testing.expectEqualStrings("refs/heads/main", refs[0].name);
    try std.testing.expectEqualStrings("refs/heads/old", refs[1].name);
}
