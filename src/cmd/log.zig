const std = @import("std");
const Writer = std.Io.Writer;
const cli = @import("../cli.zig");
const Oid = @import("../Oid.zig");
const Commit = @import("../Commit.zig");
const odb = @import("../odb.zig");
const refs = @import("../refs.zig");
const revision = @import("../revision.zig");

pub const usage = "zgit log [--oneline] [<revision>]";

pub fn run(ctx: cli.Context, args: []const []const u8) !void {
    var oneline = false;
    var spec: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--oneline")) oneline = true else spec = arg;
    }

    var repo = try ctx.openRepo();
    defer repo.close(ctx.allocator);

    const start = if (spec) |s|
        try revision.resolveOrDie(ctx.allocator, repo, s)
    else
        (try refs.resolve(ctx.allocator, repo, "HEAD")) orelse {
            const head = try refs.readHead(ctx.allocator, repo);
            defer head.deinit(ctx.allocator);
            const msg = "your current branch '{s}' does not have any commits yet";
            return cli.fatal(msg, .{refs.shortName(head.symbolic)});
        };

    // 最初の親だけを辿る。merge commit のもう片方の親は追わない (git log --first-parent 相当)
    var next: ?Oid = start;
    var first = true;
    while (next) |oid| {
        const loaded = try odb.read(ctx.allocator, repo, oid);
        defer loaded.deinit(ctx.allocator);
        if (loaded.kind != .commit)
            return cli.fatal("{f} is a {s}, not a commit", .{ oid, loaded.kind.name() });
        var commit = try Commit.parse(ctx.allocator, loaded.body);
        defer commit.deinit(ctx.allocator);

        if (oneline) {
            try ctx.out.print("{s} ", .{abbrev(oid)});
            try printSubject(ctx.out, commit.message);
        } else {
            if (!first) try ctx.out.writeByte('\n');
            try printFull(ctx.out, oid, commit);
        }
        first = false;
        next = if (commit.parents.len > 0) commit.parents[0] else null;
    }
}

/// 件名は最初の段落。git と同じく、途中の改行は空白にして 1 行で出す
fn printSubject(out: *Writer, message: []const u8) !void {
    const end = std.mem.indexOf(u8, message, "\n\n") orelse message.len;
    for (std.mem.trim(u8, message[0..end], "\n")) |c| {
        try out.writeByte(if (c == '\n') ' ' else c);
    }
    try out.writeByte('\n');
}

fn abbrev(oid: Oid) [7]u8 {
    return oid.toHex()[0..7].*;
}

/// git log の既定の形式
fn printFull(out: *Writer, oid: Oid, commit: Commit) !void {
    try out.print("commit {f}\n", .{oid});
    if (commit.parents.len > 1) {
        try out.writeAll("Merge:");
        for (commit.parents) |p| try out.print(" {s}", .{abbrev(p)});
        try out.writeByte('\n');
    }
    try out.print("Author: {s} <{s}>\n", .{ commit.author.name, commit.author.email });
    try out.writeAll("Date:   ");
    try commit.author.time.formatHuman(out);
    try out.writeAll("\n\n");

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, commit.message, "\n"), '\n');
    while (lines.next()) |line| try printMessageLine(out, line);
}

/// メッセージの 1 行。git と同じく 4 文字下げ、末尾の空白を落とし、タブは 8 桁ごとの位置まで空白にする。
/// 桁はバイト数で数えるので、日本語とタブが混じる行は git とずれる
fn printMessageLine(out: *Writer, line: []const u8) !void {
    try out.writeAll("    ");
    var column: usize = 0;
    for (std.mem.trimEnd(u8, line, " \t\r")) |c| {
        if (c == '\t') {
            const width = 8 - column % 8;
            try out.splatByteAll(' ', width);
            column += width;
        } else {
            try out.writeByte(c);
            column += 1;
        }
    }
    try out.writeByte('\n');
}
