//! "HEAD"、"main"、"ce01362" のような指定からオブジェクトの ID を得る。

const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("cli.zig");
const Repository = @import("Repository.zig");
const Oid = @import("Oid.zig");
const refs = @import("refs.zig");
const odb = @import("odb.zig");

/// 40 桁の ID → ref の名前 → 短縮 ID の順に試す。見つからなければ null
pub fn resolve(allocator: Allocator, repo: Repository, spec: []const u8) !?Oid {
    if (spec.len == Oid.hex_len) {
        if (Oid.fromHex(spec)) |oid| return oid else |_| {}
    }
    if (try refs.lookup(allocator, repo, spec)) |oid| return oid;
    if (spec.len >= 4 and spec.len < Oid.hex_len and isHex(spec)) {
        return odb.findByPrefix(repo, spec) catch |err| switch (err) {
            error.AmbiguousObject => return cli.fatal("short ID {s} is ambiguous", .{spec}),
            else => return err,
        };
    }
    return null;
}

/// 見つからなければ git と同じ文言で終了する
pub fn resolveOrDie(allocator: Allocator, repo: Repository, spec: []const u8) !Oid {
    return (try resolve(allocator, repo, spec)) orelse
        cli.fatal("Not a valid object name {s}", .{spec});
}

fn isHex(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}
