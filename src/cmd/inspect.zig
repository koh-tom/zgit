//! Git を解剖するための、本物の git には無いコマンド。
//! オブジェクトのつながりを木で描き、生のバイト列や index の中身を見せる。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const cli = @import("../cli.zig");
const Repository = @import("../Repository.zig");
const Oid = @import("../Oid.zig");
const Index = @import("../Index.zig");
const object = @import("../object.zig");
const odb = @import("../odb.zig");
const refs = @import("../refs.zig");
const revision = @import("../revision.zig");

pub const usage = "zgit inspect [<revision>] | inspect --raw <revision> | inspect index";

pub fn run(ctx: cli.Context, args: []const []const u8) !void {
    const allocator = ctx.allocator;
    const out = ctx.out;
    var repo = try ctx.openRepo();
    defer repo.close(allocator);

    if (args.len == 1 and std.mem.eql(u8, args[0], "index"))
        return inspectIndex(allocator, out, repo);
    if (args.len == 2 and std.mem.eql(u8, args[0], "--raw")) {
        const oid = try revision.resolveOrDie(allocator, repo, args[1]);
        return inspectRaw(allocator, out, repo, oid);
    }
    if (args.len > 1) return error.Usage;

    const spec = if (args.len == 1) args[0] else "HEAD";
    const oid = (try revision.resolve(allocator, repo, spec)) orelse
        return cli.fatal("Not a valid object name {s}", .{spec});
    if (std.mem.eql(u8, spec, "HEAD")) {
        const head = try refs.readHead(allocator, repo);
        defer head.deinit(allocator);
        switch (head) {
            .symbolic => |name| try out.print("HEAD -> {s}\n", .{name}),
            .detached => try out.writeAll("HEAD (detached)\n"),
        }
    } else {
        try out.print("{s}\n", .{spec});
    }
    try drawObject(allocator, out, repo, oid, "", "", null);
}

/// オブジェクトを 1 行で描き、中身 (tree なら entry、commit なら tree と親) を枝にして続ける
fn drawObject(
    allocator: Allocator,
    out: *Writer,
    repo: Repository,
    oid: Oid,
    prefix: []const u8,
    branch: []const u8,
    label: ?[]const u8,
) !void {
    const loaded = odb.read(allocator, repo, oid) catch |err| switch (err) {
        error.ObjectNotFound => {
            try out.print("{s}{s}{s} (missing)\n", .{ prefix, branch, oid.toHex()[0..7] });
            return;
        },
        else => return err,
    };
    defer loaded.deinit(allocator);
    var obj = try object.Object.parse(allocator, loaded.kind, loaded.body);
    defer obj.deinit(allocator);

    try out.print("{s}{s}{s} {s}", .{ prefix, branch, loaded.kind.name(), oid.toHex()[0..7] });
    if (label) |l| try out.print("  {s}", .{l});
    switch (obj) {
        .blob => try out.print("  ({d} bytes)\n", .{loaded.body.len}),
        .commit => |c| try out.print("  \"{s}\"\n", .{c.summary()}),
        .tree, .tag => try out.writeByte('\n'),
    }

    // 子の枝の縦線。自分が最後の子なら空白になる
    const last_child = std.mem.eql(u8, branch, "└── ");
    const bar: []const u8 = if (branch.len == 0) "" else if (last_child) "    " else "│   ";
    const child_prefix = try std.mem.concat(allocator, u8, &.{ prefix, bar });
    defer allocator.free(child_prefix);

    switch (obj) {
        .commit => |c| {
            const tree_mark = if (c.parents.len == 0) "└── " else "├── ";
            try drawObject(allocator, out, repo, c.tree, child_prefix, tree_mark, null);
            for (c.parents, 0..) |p, i| {
                const last = i + 1 == c.parents.len;
                const mark = if (last) "└── " else "├── ";
                try drawParent(allocator, out, repo, p, child_prefix, mark);
            }
        },
        .tree => |t| {
            for (t.entries, 0..) |e, i| {
                const last = i + 1 == t.entries.len;
                const name = if (e.mode == .directory)
                    try std.fmt.allocPrint(allocator, "{s}/", .{e.name})
                else
                    try allocator.dupe(u8, e.name);
                defer allocator.free(name);
                const mark = if (last) "└── " else "├── ";
                try drawObject(allocator, out, repo, e.oid, child_prefix, mark, name);
            }
        },
        .blob, .tag => {},
    }
}

/// 親は 1 行だけ。親の親まで描くと履歴の長さだけ伸びてしまう
fn drawParent(
    allocator: Allocator,
    out: *Writer,
    repo: Repository,
    oid: Oid,
    prefix: []const u8,
    branch: []const u8,
) !void {
    const loaded = try odb.read(allocator, repo, oid);
    defer loaded.deinit(allocator);
    var obj = try object.Object.parse(allocator, loaded.kind, loaded.body);
    defer obj.deinit(allocator);
    const summary = if (obj == .commit) obj.commit.summary() else "";
    try out.print(
        "{s}{s}parent {s}  \"{s}\"\n",
        .{ prefix, branch, oid.toHex()[0..7], summary },
    );
}

/// 展開したバイト列を、ヘッダ込みでそのまま見せる
fn inspectRaw(allocator: Allocator, out: *Writer, repo: Repository, oid: Oid) !void {
    const loaded = odb.read(allocator, repo, oid) catch |err| switch (err) {
        error.ObjectNotFound => return cli.fatal("Not a valid object name {f}", .{oid}),
        else => return err,
    };
    defer loaded.deinit(allocator);

    const hex = oid.toHex();
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
    const on_disk = (try repo.git_dir.statFile(repo.io, path, .{})).size;

    try out.print("object   {f}\n", .{oid});
    try out.print("path     .git/{s}\n", .{path});
    try out.print("on disk  {d} bytes (zlib)\n", .{on_disk});
    const header_len = loaded.buf.len - loaded.body.len;
    try out.print(
        "inflated {d} bytes = header {d} + {s} {d}\n\n",
        .{ loaded.buf.len, header_len, loaded.kind.name(), loaded.body.len },
    );
    try hexdump(out, loaded.buf);
}

/// hexdump -C 風の表示
pub fn hexdump(out: *Writer, data: []const u8) !void {
    var offset: usize = 0;
    while (offset < data.len) : (offset += 16) {
        const line = data[offset..@min(offset + 16, data.len)];
        try out.print("{x:0>8}  ", .{offset});
        for (0..16) |i| {
            if (i < line.len) {
                try out.print("{x:0>2} ", .{line[i]});
            } else {
                try out.writeAll("   ");
            }
            if (i == 7) try out.writeByte(' ');
        }
        try out.writeAll(" |");
        for (line) |c| try out.writeByte(if (std.ascii.isPrint(c)) c else '.');
        try out.writeAll("|\n");
    }
}

/// index を entry ごとに分解して見せる
fn inspectIndex(allocator: Allocator, out: *Writer, repo: Repository) !void {
    const size = (repo.git_dir.statFile(repo.io, "index", .{}) catch |err| switch (err) {
        error.FileNotFound => return cli.fatal("no index yet (nothing has been added)", .{}),
        else => return err,
    }).size;
    var index = try Index.read(allocator, repo);
    defer index.deinit();

    try out.print(
        ".git/index  {d} bytes, version {d}, {d} entries, checksum ok\n",
        .{ size, index.file_version, index.entries.items.len },
    );
    for (index.entries.items, 0..) |e, i| {
        try out.print("\n#{d}  {s}\n", .{ i, e.path });
        const short = e.oid.toHex()[0..7];
        try out.print("    mode {o}  size {d}  blob {s}", .{ e.mode, e.size, short });
        if (e.stage() != 0) try out.print("  stage {d}", .{e.stage()});
        try out.writeByte('\n');
        try out.print(
            "    ctime {d}.{d:0>9}  mtime {d}.{d:0>9}\n",
            .{ e.ctime_sec, e.ctime_nsec, e.mtime_sec, e.mtime_nsec },
        );
        try out.print(
            "    dev {d}  ino {d}  uid {d}  gid {d}  flags {x:0>4}\n",
            .{ e.dev, e.ino, e.uid, e.gid, e.flags },
        );
    }
    if (index.extensions.items.len > 0) {
        try out.writeAll("\nextensions:");
        for (index.extensions.items) |ext| {
            try out.print("  {s} ({d} bytes)", .{ ext.signature, ext.size });
        }
        try out.writeByte('\n');
    }
}
