//! Object ID。画面では 40 桁の 16 進数に見えるが、実体は SHA-1 の 20 バイト。
//! tree や index の中にはこの 20 バイトがそのまま並ぶ。

const std = @import("std");

const Oid = @This();

pub const len = 20;
pub const hex_len = len * 2;

bytes: [len]u8,

pub fn fromBytes(bytes: *const [len]u8) Oid {
    return .{ .bytes = bytes.* };
}

pub fn fromHex(hex: []const u8) error{InvalidOid}!Oid {
    if (hex.len != hex_len) return error.InvalidOid;
    var oid: Oid = undefined;
    _ = std.fmt.hexToBytes(&oid.bytes, hex) catch return error.InvalidOid;
    return oid;
}

pub fn toHex(self: Oid) [hex_len]u8 {
    return std.fmt.bytesToHex(self.bytes, .lower);
}

pub fn eql(a: Oid, b: Oid) bool {
    return std.mem.eql(u8, &a.bytes, &b.bytes);
}

/// `{f}` で 40 桁の 16 進として書き出す
pub fn format(self: Oid, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(&self.toHex());
}

test "hex round trip" {
    const hex = "ce013625030ba8dba906f756967f9e9ca394464a";
    const oid = try fromHex(hex);
    try std.testing.expectEqual(0xce, oid.bytes[0]);
    try std.testing.expectEqual(0x4a, oid.bytes[19]);
    try std.testing.expectEqualStrings(hex, &oid.toHex());
    try std.testing.expectFmt(hex, "{f}", .{oid});
}

test "rejects malformed hex" {
    try std.testing.expectError(error.InvalidOid, fromHex("ce0136"));
    try std.testing.expectError(error.InvalidOid, fromHex("zz013625030ba8dba906f756967f9e9ca394464a"));
}
