//! Git オブジェクトに共通する部分。種類と、ハッシュの計算。

const std = @import("std");
const Oid = @import("Oid.zig");

pub const Type = enum {
    blob,
    tree,
    commit,
    tag,

    pub fn name(self: Type) []const u8 {
        return @tagName(self);
    }

    pub fn parse(s: []const u8) ?Type {
        return std.meta.stringToEnum(Type, s);
    }
};

/// ヘッダ "<type> <size>\0" を `w` に書く。ハッシュにも保存にも同じものを使う
pub fn writeHeader(w: *std.Io.Writer, kind: Type, size: usize) std.Io.Writer.Error!void {
    try w.print("{s} {d}\x00", .{ kind.name(), size });
}

/// ヘッダ付きの内容全体を SHA-1 にかける。中身が同じなら同じ ID になる
pub fn hash(kind: Type, data: []const u8) Oid {
    var header_buf: [32]u8 = undefined;
    var header = std.Io.Writer.fixed(&header_buf);
    writeHeader(&header, kind, data.len) catch unreachable;

    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(header.buffered());
    sha1.update(data);

    var oid: Oid = undefined;
    sha1.final(&oid.bytes);
    return oid;
}

test "blob hash matches git hash-object" {
    // $ printf 'hello\n' | git hash-object --stdin
    const oid = hash(.blob, "hello\n");
    try std.testing.expectFmt("ce013625030ba8dba906f756967f9e9ca394464a", "{f}", .{oid});

    // 空の blob。Git を使っていると時々見かける ID
    const empty = hash(.blob, "");
    try std.testing.expectFmt("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", "{f}", .{empty});
}

test "type names round trip" {
    try std.testing.expectEqual(Type.tree, Type.parse("tree").?);
    try std.testing.expectEqual(null, Type.parse("blobs"));
    try std.testing.expectEqualStrings("commit", Type.commit.name());
}
