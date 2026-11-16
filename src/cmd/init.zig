const cli = @import("../cli.zig");
const Repository = @import("../Repository.zig");

pub const usage = "zgit init [<directory>]";

pub fn run(ctx: cli.Context, args: []const []const u8) !void {
    const path = if (args.len > 0) args[0] else ".";
    try Repository.init(ctx.io, path);

    var repo = try Repository.discover(ctx.allocator, ctx.io, ctx.env, path);
    defer repo.close(ctx.allocator);
    try ctx.out.print("Initialized empty Git repository in {s}/.git/\n", .{repo.work_path});
}
