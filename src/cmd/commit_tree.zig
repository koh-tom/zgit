const std = @import("std");
const cli = @import("../cli.zig");
const Oid = @import("../Oid.zig");
const Commit = @import("../Commit.zig");
const odb = @import("../odb.zig");
const ident = @import("../ident.zig");

pub const usage = "zgit commit-tree <tree> [-p <parent>]... -m <message>";

pub fn run(ctx: cli.Context, args: []const []const u8) !void {
    var repo = try ctx.openRepo();
    defer repo.close(ctx.allocator);

    var tree: ?Oid = null;
    var message: ?[]const u8 = null;
    var parents: std.ArrayList(Oid) = .empty;
    defer parents.deinit(ctx.allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i == args.len) return error.Usage;
            const parent = Oid.fromHex(args[i]) catch
                return cli.fatal("Not a valid object name {s}", .{args[i]});
            try parents.append(ctx.allocator, parent);
        } else if (std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i == args.len) return error.Usage;
            message = args[i];
        } else {
            tree = Oid.fromHex(arg) catch
                return cli.fatal("Not a valid object name {s}", .{arg});
        }
    }

    // tree 以外を指す commit は git fsck に通らないので、ここで断る
    const tree_oid = tree orelse return error.Usage;
    const loaded = odb.read(ctx.allocator, repo, tree_oid) catch |err| switch (err) {
        error.ObjectNotFound => return cli.fatal("Not a valid object name {f}", .{tree_oid}),
        else => return err,
    };
    defer loaded.deinit(ctx.allocator);
    if (loaded.kind != .tree) return cli.fatal("{f} is not a valid 'tree' object", .{tree_oid});

    const commit = Commit{
        .tree = tree_oid,
        .parents = parents.items,
        .author = try ident.signature(ctx.allocator, repo, .author),
        .committer = try ident.signature(ctx.allocator, repo, .committer),
        .message = try Commit.withNewline(ctx.allocator, message orelse return error.Usage),
    };
    try ctx.out.print("{f}\n", .{try commit.write(ctx.allocator, repo)});
}
