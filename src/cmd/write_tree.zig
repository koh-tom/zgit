const cli = @import("../cli.zig");
const worktree = @import("../worktree.zig");

pub const usage = "zgit write-tree";

pub fn run(ctx: cli.Context, _: []const []const u8) !void {
    var repo = try ctx.openRepo();
    defer repo.close(ctx.allocator);
    try ctx.out.print("{f}\n", .{try worktree.writeTree(ctx.allocator, repo)});
}
