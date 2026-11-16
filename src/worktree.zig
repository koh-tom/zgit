//! 作業ツリー (チェックアウトされているファイル群) の走査。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Repository = @import("Repository.zig");
const Oid = @import("Oid.zig");
const Tree = @import("Tree.zig");
const odb = @import("odb.zig");
const stat = @import("stat.zig");

const max_file_size = 1 << 30;

/// 作業ツリーの中身をそのまま tree オブジェクトにして ID を返す。
/// 本物の git は index から tree を作るが、index ができるまではこれで代用する
pub fn writeTree(allocator: Allocator, repo: Repository) !Oid {
    var dir = try repo.work_dir.openDir(repo.io, ".", .{ .iterate = true });
    defer dir.close(repo.io);
    return (try writeDir(allocator, repo, dir)) orelse odb.write(repo, .tree, "");
}

/// 1 ディレクトリ分。空ディレクトリは git と同じく無かったことにする (null)
fn writeDir(allocator: Allocator, repo: Repository, dir: Dir) !?Oid {
    // この関数の中でしか使わないものは arena にまとめて、最後に一括で返す
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const io = repo.io;

    var entries: std.ArrayList(Tree.Entry) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |ent| {
        if (std.mem.eql(u8, ent.name, ".git")) continue;
        const name = try scratch.dupe(u8, ent.name);

        const entry: Tree.Entry = switch (ent.kind) {
            .directory => blk: {
                var sub = try dir.openDir(io, name, .{ .iterate = true });
                defer sub.close(io);
                const oid = (try writeDir(allocator, repo, sub)) orelse continue;
                break :blk .{ .mode = .directory, .name = name, .oid = oid };
            },
            .file => blk: {
                const data = try dir.readFileAlloc(io, name, scratch, .limited(max_file_size));
                const st = try dir.statFile(io, name, .{});
                const executable = st.permissions.toMode() & 0o100 != 0;
                const mode: Tree.Mode = if (executable) .executable else .regular;
                const oid = try odb.write(repo, .blob, data);
                break :blk .{ .mode = mode, .name = name, .oid = oid };
            },
            .sym_link => blk: {
                // シンボリックリンクはリンク先のパス文字列が blob になる
                var target_buf: [Dir.max_path_bytes]u8 = undefined;
                const len = try dir.readLink(io, name, &target_buf);
                const oid = try odb.write(repo, .blob, target_buf[0..len]);
                break :blk .{ .mode = .symlink, .name = name, .oid = oid };
            },
            else => continue,
        };
        try entries.append(scratch, entry);
    }
    if (entries.items.len == 0) return null;

    Tree.sort(entries.items);
    var out: std.Io.Writer.Allocating = .init(scratch);
    try (Tree{ .entries = entries.items }).serialize(&out.writer);
    return try odb.write(repo, .tree, out.written());
}

/// コマンドラインで受け取ったパスを、作業ツリーのルートからの相対パスに直す。ルート自身は ""
pub fn normalize(allocator: Allocator, repo: Repository, arg: []const u8) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(repo.io, allocator);
    defer allocator.free(cwd);
    const abs = try Dir.path.resolveAlloc(allocator, &.{ cwd, arg });
    defer allocator.free(abs);
    const rel = try Dir.path.relativeAlloc(allocator, cwd, null, repo.work_path, abs);
    errdefer allocator.free(rel);
    const outside = std.mem.eql(u8, rel, "..") or std.mem.startsWith(u8, rel, "../");
    if (outside) return error.OutsideRepository;
    return rel;
}

/// シンボリックリンクを辿らずに stat する。リンク自体を index に載せるため
pub fn lstat(repo: Repository, path: []const u8) !stat.Stat {
    return stat.lstat(repo.work_dir, path);
}

pub fn exists(repo: Repository, path: []const u8) bool {
    _ = lstat(repo, path) catch return false;
    return true;
}

/// blob にする中身。通常ファイルは内容そのもの、シンボリックリンクはリンク先のパス
pub fn readFile(
    allocator: Allocator,
    repo: Repository,
    path: []const u8,
    st: stat.Stat,
) ![]u8 {
    if (st.isSymlink()) {
        var buf: [Dir.max_path_bytes]u8 = undefined;
        const len = try repo.work_dir.readLink(repo.io, path, &buf);
        return allocator.dupe(u8, buf[0..len]);
    }
    return repo.work_dir.readFileAlloc(repo.io, path, allocator, .limited(max_file_size));
}

/// `dir` 以下の全ファイルを、ルートからの相対パスで列挙する。.git は見ない
pub fn listFiles(
    allocator: Allocator,
    repo: Repository,
    dir: []const u8,
) ![]const []const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    const start = if (dir.len == 0) "." else dir;
    var root = try repo.work_dir.openDir(repo.io, start, .{ .iterate = true });
    defer root.close(repo.io);
    var walker = try root.walk(allocator);
    defer walker.deinit();
    while (try walker.next(repo.io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        const in_git = std.mem.startsWith(u8, entry.path, ".git/") or
            std.mem.indexOf(u8, entry.path, "/.git/") != null;
        if (in_git) continue;
        const path = if (dir.len == 0)
            try allocator.dupe(u8, entry.path)
        else
            try Dir.path.join(allocator, &.{ dir, entry.path });
        try files.append(allocator, path);
    }
    return files.toOwnedSlice(allocator);
}

pub fn freeFiles(allocator: Allocator, files: []const []const u8) void {
    for (files) |f| allocator.free(f);
    allocator.free(files);
}

/// `path` が `dir` の下にあるか。dir が "" ならルートなので常に真
pub fn contains(dir: []const u8, path: []const u8) bool {
    if (dir.len == 0) return true;
    return path.len > dir.len and std.mem.startsWith(u8, path, dir) and path[dir.len] == '/';
}
