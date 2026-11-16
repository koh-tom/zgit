const std = @import("std");
const cli = @import("../cli.zig");
const Repository = @import("../Repository.zig");
const refs = @import("../refs.zig");
const revision = @import("../revision.zig");
const ident = @import("../ident.zig");

pub const usage = "zgit branch [<name> [<start-point>]]";

pub fn run(ctx: cli.Context, args: []const []const u8) !void {
    var repo = try ctx.openRepo();
    defer repo.close(ctx.allocator);

    switch (args.len) {
        0 => try list(ctx, repo),
        1, 2 => try create(ctx, repo, args[0], if (args.len == 2) args[1] else "HEAD"),
        else => return error.Usage,
    }
}

/// 今いるブランチに * を付けて一覧する
fn list(ctx: cli.Context, repo: Repository) !void {
    const head = try refs.readHead(ctx.allocator, repo);
    defer head.deinit(ctx.allocator);

    const branches = try refs.list(ctx.allocator, repo, "refs/heads");
    defer refs.freeList(ctx.allocator, branches);
    for (branches) |b| {
        const current = head == .symbolic and std.mem.eql(u8, head.symbolic, b.name);
        const mark = if (current) "*" else " ";
        try ctx.out.print("{s} {s}\n", .{ mark, b.name["refs/heads/".len..] });
    }
}

/// ブランチを作るとは、refs/heads/<name> というファイルを 1 つ置くこと
fn create(ctx: cli.Context, repo: Repository, name: []const u8, start: []const u8) !void {
    if (!validName(name)) return cli.fatal("'{s}' is not a valid branch name", .{name});
    const full = try std.fmt.allocPrint(ctx.allocator, "refs/heads/{s}", .{name});
    defer ctx.allocator.free(full);
    if (try refs.resolve(ctx.allocator, repo, full) != null)
        return cli.fatal("a branch named '{s}' already exists", .{name});

    const oid = (try revision.resolve(ctx.allocator, repo, start)) orelse
        return cli.fatal("not a valid object name: '{s}'", .{start});
    const message = try std.fmt.allocPrint(ctx.allocator, "branch: Created from {s}", .{start});
    defer ctx.allocator.free(message);
    try refs.update(ctx.allocator, repo, full, oid, .{
        .who = try ident.signature(ctx.allocator, repo, .committer),
        .message = message,
    });
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '-' or name[0] == '/' or name[name.len - 1] == '/')
        return false;
    if (std.mem.indexOf(u8, name, "..") != null or std.mem.endsWith(u8, name, ".lock"))
        return false;
    for (name) |c| {
        if (std.ascii.isControl(c) or std.mem.indexOfScalar(u8, " ~^:?*[\\", c) != null)
            return false;
    }
    return true;
}
