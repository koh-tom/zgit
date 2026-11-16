const std = @import("std");
const cli = @import("../cli.zig");
const Tree = @import("../Tree.zig");
const odb = @import("../odb.zig");
const revision = @import("../revision.zig");
const ls_tree = @import("ls_tree.zig");

pub const usage = "zgit cat-file (-t | -s | -p) <object>";

pub fn run(ctx: cli.Context, args: []const []const u8) !void {
    if (args.len != 2) return error.Usage;
    const mode = args[0];
    const name = args[1];

    var repo = try ctx.openRepo();
    defer repo.close(ctx.allocator);

    const oid = try revision.resolveOrDie(ctx.allocator, repo, name);
    const loaded = odb.read(ctx.allocator, repo, oid) catch |err| switch (err) {
        error.ObjectNotFound => return cli.fatal("Not a valid object name {s}", .{name}),
        else => return err,
    };
    defer loaded.deinit(ctx.allocator);

    if (std.mem.eql(u8, mode, "-t")) {
        try ctx.out.print("{s}\n", .{loaded.kind.name()});
    } else if (std.mem.eql(u8, mode, "-s")) {
        try ctx.out.print("{d}\n", .{loaded.body.len});
    } else if (std.mem.eql(u8, mode, "-p")) {
        switch (loaded.kind) {
            // tree だけはバイナリなので、ls-tree と同じ形で見せる
            .tree => {
                var tree = try Tree.parse(ctx.allocator, loaded.body);
                defer tree.deinit(ctx.allocator);
                for (tree.entries) |e| try ls_tree.printEntry(ctx.out, e, "");
            },
            else => try ctx.out.writeAll(loaded.body),
        }
    } else {
        return error.Usage;
    }
}
