const std = @import("std");
const Io = std.Io;
const cli = @import("cli.zig");

const version = "0.1.0";

const Command = struct {
    name: []const u8,
    usage: []const u8,
    run: *const fn (cli.Context, []const []const u8) anyerror!void,
};

const commands = [_]Command{
    command("init", @import("cmd/init.zig")),
    command("hash-object", @import("cmd/hash_object.zig")),
    command("cat-file", @import("cmd/cat_file.zig")),
    command("ls-tree", @import("cmd/ls_tree.zig")),
    command("write-tree", @import("cmd/write_tree.zig")),
    command("commit-tree", @import("cmd/commit_tree.zig")),
    command("update-ref", @import("cmd/update_ref.zig")),
    command("rev-parse", @import("cmd/rev_parse.zig")),
    command("branch", @import("cmd/branch.zig")),
    command("log", @import("cmd/log.zig")),
    .{ .name = "version", .usage = "zgit version", .run = runVersion },
};

fn command(name: []const u8, comptime impl: type) Command {
    return .{ .name = name, .usage = impl.usage, .run = impl.run };
}

pub fn main(init: std.process.Init) u8 {
    // init.arena はプロセスと同じ寿命。CLI は一度きりなので、確保したメモリは全部ここに置く
    const allocator = init.arena.allocator();

    var buf: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .initStreaming(.stdout(), init.io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const ctx: cli.Context = .{
        .allocator = allocator,
        .io = init.io,
        .out = out,
        .env = init.environ_map,
    };

    const args = init.minimal.args.toSlice(allocator) catch return 1;
    if (args.len < 2) {
        usage(out) catch {};
        return 1;
    }

    const cmd = findCommand(args[1]) orelse {
        std.debug.print("zgit: '{s}' is not a zgit command\n", .{args[1]});
        return 1;
    };
    cmd.run(ctx, args[2..]) catch |err| {
        out.flush() catch {};
        switch (err) {
            error.Fatal => {},
            // `zgit log | head` のように出力先が先に閉じた。git と同じく黙って終わる
            error.WriteFailed => return 141,
            error.Usage => {
                std.debug.print("usage: {s}\n", .{cmd.usage});
                return 129;
            },
            else => std.debug.print("fatal: {s}\n", .{describe(err)}),
        }
        return 128;
    };
    return 0;
}

/// エラーを git と同じ調子の文言にする。知らないものは名前をそのまま出す
fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.NotARepository => "not a git repository (or any of the parent directories): .git",
        error.MissingIdentity => "no user.name or user.email (set them with git config)",
        error.InvalidDate => "dates in GIT_*_DATE must look like \"1700000000 +0900\"",
        else => @errorName(err),
    };
}

fn findCommand(name: []const u8) ?Command {
    for (commands) |cmd| {
        if (std.mem.eql(u8, cmd.name, name)) return cmd;
    }
    return null;
}

fn usage(out: *Io.Writer) !void {
    try out.writeAll("usage: zgit <command> [<args>]\n\ncommands:\n");
    for (commands) |cmd| {
        try out.print("   {s}\n", .{cmd.name});
    }
}

fn runVersion(ctx: cli.Context, _: []const []const u8) !void {
    try ctx.out.print("zgit version {s}\n", .{version});
}

test {
    std.testing.refAllDecls(@This());
}
