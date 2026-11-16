const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("../cli.zig");
const Repository = @import("../Repository.zig");
const Oid = @import("../Oid.zig");
const Commit = @import("../Commit.zig");
const Index = @import("../Index.zig");
const odb = @import("../odb.zig");
const refs = @import("../refs.zig");
const ident = @import("../ident.zig");

pub const usage = "zgit commit -m <message>";

pub fn run(ctx: cli.Context, args: []const []const u8) !void {
    const allocator = ctx.allocator;
    var message: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-m") and i + 1 < args.len) {
            i += 1;
            message = args[i];
        } else {
            return error.Usage;
        }
    }
    const text = try Commit.withNewline(allocator, message orelse return error.Usage);

    var repo = try ctx.openRepo();
    defer repo.close(allocator);

    // index → tree。add したものがそのままスナップショットになる
    var index = try Index.read(allocator, repo);
    defer index.deinit();
    const tree = try index.writeTree(repo);

    // 親は今の HEAD。最初の commit には無い
    const head = try refs.readHead(allocator, repo);
    defer head.deinit(allocator);
    const parent = try refs.resolve(allocator, repo, "HEAD");
    if (parent) |p| {
        if (tree.eql(try treeOf(allocator, repo, p)))
            return cli.fatal("nothing to commit, working tree clean", .{});
    } else if (index.entries.items.len == 0) {
        return cli.fatal("nothing to commit (nothing has been added)", .{});
    }

    const commit = Commit{
        .tree = tree,
        .parents = if (parent) |p| &.{p} else &.{},
        .author = try ident.signature(allocator, repo, .author),
        .committer = try ident.signature(allocator, repo, .committer),
        .message = text,
    };
    const oid = try commit.write(allocator, repo);

    // HEAD の指すブランチを進める。reflog には git と同じ文言を残す
    const initial: []const u8 = if (parent == null) " (initial)" else "";
    const log_message =
        try std.fmt.allocPrint(allocator, "commit{s}: {s}", .{ initial, commit.summary() });
    defer allocator.free(log_message);
    const reflog: refs.Reflog = .{ .who = commit.committer, .message = log_message };
    try refs.update(allocator, repo, "HEAD", oid, reflog);

    const branch = switch (head) {
        .symbolic => |name| refs.shortName(name),
        .detached => "detached HEAD",
    };
    const root: []const u8 = if (parent == null) " (root-commit)" else "";
    try ctx.out.print(
        "[{s}{s} {s}] {s}\n",
        .{ branch, root, oid.toHex()[0..7], commit.summary() },
    );
}

fn treeOf(allocator: Allocator, repo: Repository, oid: Oid) !Oid {
    const loaded = try odb.read(allocator, repo, oid);
    defer loaded.deinit(allocator);
    var commit = try Commit.parse(allocator, loaded.body);
    defer commit.deinit(allocator);
    return commit.tree;
}
