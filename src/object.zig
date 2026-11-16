//! Git オブジェクトに共通する部分。種類と、ハッシュの計算。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Oid = @import("Oid.zig");
const Tree = @import("Tree.zig");
const Commit = @import("Commit.zig");

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

/// 解析済みのオブジェクト。4 種類のどれか 1 つ
pub const Object = union(Type) {
    blob: []const u8,
    tree: Tree,
    commit: Commit,
    /// annotated tag。本書では作らないので中身はテキストのまま
    tag: []const u8,

    /// `body` を種類に応じて解析する。tree / commit の文字列は `body` の中を指す
    pub fn parse(allocator: Allocator, kind: Type, body: []const u8) !Object {
        return switch (kind) {
            .blob => .{ .blob = body },
            .tree => .{ .tree = try Tree.parse(allocator, body) },
            .commit => .{ .commit = try Commit.parse(allocator, body) },
            .tag => .{ .tag = body },
        };
    }

    pub fn deinit(self: *Object, allocator: Allocator) void {
        switch (self.*) {
            .tree => |*t| t.deinit(allocator),
            .commit => |*c| c.deinit(allocator),
            .blob, .tag => {},
        }
    }
};

pub const Header = struct {
    kind: Type,
    size: usize,
    /// ヘッダの長さ。本体は buf[header_len..]
    header_len: usize,
};

pub const HeaderError = error{ CorruptObject, UnknownObjectType };

/// 展開済みオブジェクトの先頭 "<type> <size>\0" を読む
pub fn parseHeader(buf: []const u8) HeaderError!Header {
    const end = std.mem.indexOfScalar(u8, buf[0..@min(buf.len, 32)], 0) orelse
        return error.CorruptObject;
    const space = std.mem.indexOfScalar(u8, buf[0..end], ' ') orelse return error.CorruptObject;
    const kind = Type.parse(buf[0..space]) orelse return error.UnknownObjectType;
    const size = std.fmt.parseInt(usize, buf[space + 1 .. end], 10) catch
        return error.CorruptObject;
    return .{ .kind = kind, .size = size, .header_len = end + 1 };
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

test "parse header" {
    const h = try parseHeader("blob 6\x00hello\n");
    try std.testing.expectEqual(Type.blob, h.kind);
    try std.testing.expectEqual(6, h.size);
    try std.testing.expectEqual(7, h.header_len);

    try std.testing.expectError(error.UnknownObjectType, parseHeader("blobby 6\x00"));
    try std.testing.expectError(error.CorruptObject, parseHeader("blob six\x00"));
    try std.testing.expectError(error.CorruptObject, parseHeader("blob 6 hello"));
}

test "type names round trip" {
    try std.testing.expectEqual(Type.tree, Type.parse("tree").?);
    try std.testing.expectEqual(null, Type.parse("blobs"));
    try std.testing.expectEqualStrings("commit", Type.commit.name());
}
