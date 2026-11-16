const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const object = @import("../object.zig");

pub const usage = "zgit hash-object [--stdin] [<file>]";

const max_file_size = 1 << 30;

pub fn run(ctx: cli.Context, args: []const []const u8) !void {
    var path: ?[]const u8 = null;
    var use_stdin = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--stdin")) {
            use_stdin = true;
        } else {
            path = arg;
        }
    }

    const data = if (use_stdin)
        try readStdin(ctx)
    else if (path) |p|
        try Io.Dir.cwd().readFileAlloc(ctx.io, p, ctx.allocator, .limited(max_file_size))
    else
        return error.Usage;
    defer ctx.allocator.free(data);

    try ctx.out.print("{f}\n", .{object.hash(.blob, data)});
}

fn readStdin(ctx: cli.Context) ![]u8 {
    var buf: [4096]u8 = undefined;
    var reader: Io.File.Reader = .init(.stdin(), ctx.io, &buf);
    return reader.interface.allocRemaining(ctx.allocator, .limited(max_file_size));
}
