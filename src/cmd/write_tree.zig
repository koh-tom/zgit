const cli = @import("../cli.zig");
const Index = @import("../Index.zig");

pub const usage = "zgit write-tree";

pub fn run(ctx: cli.Context, _: []const []const u8) !void {
    var repo = try ctx.openRepo();
    defer repo.close(ctx.allocator);
    var index = try Index.read(ctx.allocator, repo);
    defer index.deinit();
    try ctx.out.print("{f}\n", .{try index.writeTree(repo)});
}
