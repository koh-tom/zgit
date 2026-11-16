const cli = @import("../cli.zig");
const revision = @import("../revision.zig");

pub const usage = "zgit rev-parse <revision>...";

pub fn run(ctx: cli.Context, args: []const []const u8) !void {
    if (args.len == 0) return error.Usage;
    var repo = try ctx.openRepo();
    defer repo.close(ctx.allocator);
    for (args) |spec| {
        try ctx.out.print("{f}\n", .{try revision.resolveOrDie(ctx.allocator, repo, spec)});
    }
}
