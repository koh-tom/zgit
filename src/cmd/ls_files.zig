const std = @import("std");
const cli = @import("../cli.zig");
const Index = @import("../Index.zig");

pub const usage = "zgit ls-files [-s | --stage] [--debug]";

pub fn run(ctx: cli.Context, args: []const []const u8) !void {
    var stage = false;
    var debug = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--stage")) {
            stage = true;
        } else if (std.mem.eql(u8, arg, "--debug")) {
            debug = true;
        } else {
            return error.Usage;
        }
    }

    var repo = try ctx.openRepo();
    defer repo.close(ctx.allocator);
    var index = try Index.read(ctx.allocator, repo);
    defer index.deinit();

    const out = ctx.out;
    for (index.entries.items) |e| {
        if (stage) try out.print("{o} {f} {d}\t", .{ e.mode, e.oid, e.stage() });
        try out.print("{s}\n", .{e.path});
        if (debug) {
            // git ls-files --debug と同じ形。index に入っている stat 情報が見える
            try out.print("  ctime: {d}:{d}\n", .{ e.ctime_sec, e.ctime_nsec });
            try out.print("  mtime: {d}:{d}\n", .{ e.mtime_sec, e.mtime_nsec });
            try out.print("  dev: {d}\tino: {d}\n", .{ e.dev, e.ino });
            try out.print("  uid: {d}\tgid: {d}\n", .{ e.uid, e.gid });
            const flags = e.flags & ~Index.Entry.name_mask;
            try out.print("  size: {d}\tflags: {x}\n", .{ e.size, flags });
        }
    }
}
