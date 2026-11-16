//! 作業ツリー (チェックアウトされているファイル群) の走査。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Repository = @import("Repository.zig");
const Oid = @import("Oid.zig");
const Tree = @import("Tree.zig");
const odb = @import("odb.zig");

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
