const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const cli = @import("../cli.zig");
const Repository = @import("../Repository.zig");
const Oid = @import("../Oid.zig");
const Tree = @import("../Tree.zig");
const Commit = @import("../Commit.zig");
const odb = @import("../odb.zig");

pub const usage = "zgit ls-tree [-r] <tree-ish>";

pub fn run(ctx: cli.Context, args: []const []const u8) !void {
    var recursive = false;
    var name: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-r")) recursive = true else name = arg;
    }
    const target = name orelse return error.Usage;

    var repo = try ctx.openRepo();
    defer repo.close(ctx.allocator);

    const oid = Oid.fromHex(target) catch
        return cli.fatal("Not a valid object name {s}", .{target});
    try list(ctx.allocator, ctx.out, repo, oid, "", recursive);
}

/// 1 階層分を表示する。`-r` ならディレクトリの中へ降りていく
pub fn list(
    allocator: Allocator,
    out: *Writer,
    repo: Repository,
    oid: Oid,
    prefix: []const u8,
    recursive: bool,
) !void {
    const loaded = odb.read(allocator, repo, oid) catch |err| switch (err) {
        error.ObjectNotFound => return cli.fatal("Not a valid object name {f}", .{oid}),
        else => return err,
    };
    defer loaded.deinit(allocator);

    switch (loaded.kind) {
        .tree => {},
        // commit を渡されたら、その commit が指す tree を見せる
        .commit => {
            var commit = try Commit.parse(allocator, loaded.body);
            defer commit.deinit(allocator);
            return list(allocator, out, repo, commit.tree, prefix, recursive);
        },
        else => return cli.fatal("not a tree object", .{}),
    }

    var tree = try Tree.parse(allocator, loaded.body);
    defer tree.deinit(allocator);

    for (tree.entries) |e| {
        if (recursive and e.mode == .directory) {
            const sub = try std.fmt.allocPrint(allocator, "{s}{s}/", .{ prefix, e.name });
            defer allocator.free(sub);
            try list(allocator, out, repo, e.oid, sub, true);
        } else {
            try printEntry(out, e, prefix);
        }
    }
}

/// git ls-tree と同じ "100644 blob <oid>\t<name>" の形式。mode は 6 桁に揃える
pub fn printEntry(out: *Writer, e: Tree.Entry, prefix: []const u8) !void {
    try out.print(
        "{o:0>6} {s} {f}\t{s}{s}\n",
        .{ @backingInt(e.mode), e.mode.objectType().name(), e.oid, prefix, e.name },
    );
}
