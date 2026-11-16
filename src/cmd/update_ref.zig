const cli = @import("../cli.zig");
const refs = @import("../refs.zig");
const revision = @import("../revision.zig");
const ident = @import("../ident.zig");

pub const usage = "zgit update-ref <ref> <revision>";

pub fn run(ctx: cli.Context, args: []const []const u8) !void {
    if (args.len != 2) return error.Usage;
    var repo = try ctx.openRepo();
    defer repo.close(ctx.allocator);

    const oid = try revision.resolveOrDie(ctx.allocator, repo, args[1]);
    try refs.update(ctx.allocator, repo, args[0], oid, .{
        .who = try ident.signature(ctx.allocator, repo, .committer),
        .message = "",
    });
}
