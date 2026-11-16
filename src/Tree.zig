//! tree オブジェクト。ディレクトリ 1 階層分の一覧で、
//! "<mode> <name>\0<20 byte の oid>" が名前順に並んでいるだけのバイト列。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Oid = @import("Oid.zig");
const object = @import("object.zig");

const Tree = @This();

entries: []Entry,

pub const Mode = enum(u32) {
    regular = 0o100644,
    executable = 0o100755,
    symlink = 0o120000,
    directory = 0o040000,
    /// submodule。中身は別リポジトリの commit を指す
    gitlink = 0o160000,

    pub fn parse(s: []const u8) error{InvalidMode}!Mode {
        const n = std.fmt.parseInt(u32, s, 8) catch return error.InvalidMode;
        return std.enums.fromInt(Mode, n) orelse error.InvalidMode;
    }

    pub fn objectType(self: Mode) object.Type {
        return switch (self) {
            .directory => .tree,
            .gitlink => .commit,
            else => .blob,
        };
    }

    /// tree の中での表記。先頭の 0 を付けないので directory は "40000" になる
    pub fn format(self: Mode, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{o}", .{@backingInt(self)});
    }
};

pub const Entry = struct {
    mode: Mode,
    name: []const u8,
    oid: Oid,
};

pub const ParseError = error{ CorruptTree, InvalidMode } || Allocator.Error;

/// `data` を解析する。entry の `name` は `data` の中を指すので、`data` より長生きさせない
pub fn parse(allocator: Allocator, data: []const u8) ParseError!Tree {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(allocator);

    var rest = data;
    while (rest.len > 0) {
        const space = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.CorruptTree;
        const nul = std.mem.indexOfScalarPos(u8, rest, space + 1, 0) orelse
            return error.CorruptTree;
        const end = nul + 1 + Oid.len;
        if (rest.len < end) return error.CorruptTree;

        try entries.append(allocator, .{
            .mode = try Mode.parse(rest[0..space]),
            .name = rest[space + 1 .. nul],
            .oid = Oid.fromBytes(rest[nul + 1 .. end][0..Oid.len]),
        });
        rest = rest[end..];
    }
    return .{ .entries = try entries.toOwnedSlice(allocator) };
}

pub fn deinit(self: *Tree, allocator: Allocator) void {
    allocator.free(self.entries);
    self.* = undefined;
}

/// entries をそのままの順で書き出す。書く前に `sort` しておくこと
pub fn serialize(self: Tree, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (self.entries) |e| {
        try w.print("{f} {s}\x00", .{ e.mode, e.name });
        try w.writeAll(&e.oid.bytes);
    }
}

/// git の順序に並べる。ディレクトリは名前の後ろに '/' が付いているものとして比べる
pub fn sort(entries: []Entry) void {
    std.mem.sort(Entry, entries, {}, lessThan);
}

fn lessThan(_: void, a: Entry, b: Entry) bool {
    const n = @min(a.name.len, b.name.len);
    return switch (std.mem.order(u8, a.name[0..n], b.name[0..n])) {
        .lt => true,
        .gt => false,
        .eq => byteAfter(a, n) < byteAfter(b, n),
    };
}

fn byteAfter(e: Entry, i: usize) u8 {
    if (i < e.name.len) return e.name[i];
    return if (e.mode == .directory) '/' else 0;
}

test "parse what git wrote" {
    // $ git cat-file tree d2f3d07c3315c88bc53c35daec28174a76ad33f6 | xxd
    const data = "100644 hello.txt\x00" ++ "\xce\x01\x36\x25\x03\x0b\xa8\xdb\xa9\x06\xf7\x56\x96\x7f\x9e\x9c\xa3\x94\x46\x4a" ++
        "40000 src\x00" ++ "\x2e\x30\x24\x31\x94\x3b\xbd\xef\xc4\x97\xdd\xd1\x46\xd0\xeb\xd3\xef\x94\x89\xce";

    var tree = try parse(std.testing.allocator, data);
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(2, tree.entries.len);
    try std.testing.expectEqual(Mode.regular, tree.entries[0].mode);
    try std.testing.expectEqualStrings("hello.txt", tree.entries[0].name);
    try std.testing.expectFmt("ce013625030ba8dba906f756967f9e9ca394464a", "{f}", .{tree.entries[0].oid});
    try std.testing.expectEqual(Mode.directory, tree.entries[1].mode);
    try std.testing.expectEqualStrings("src", tree.entries[1].name);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try tree.serialize(&out.writer);
    try std.testing.expectEqualSlices(u8, data, out.written());
    try std.testing.expectFmt("d2f3d07c3315c88bc53c35daec28174a76ad33f6", "{f}", .{object.hash(.tree, out.written())});
}

test "rejects truncated data" {
    try std.testing.expectError(error.CorruptTree, parse(std.testing.allocator, "100644 a\x00short"));
    const zeros: [Oid.len]u8 = @splat(0);
    try std.testing.expectError(error.InvalidMode, parse(std.testing.allocator, "100777 a\x00" ++ zeros));
}

test "directories sort as if they ended with a slash" {
    const zero = Oid.fromBytes(&@as([Oid.len]u8, @splat(0)));
    var entries = [_]Entry{
        .{ .mode = .directory, .name = "foo", .oid = zero },
        .{ .mode = .regular, .name = "foo.txt", .oid = zero },
        .{ .mode = .regular, .name = "foo-bar", .oid = zero },
        .{ .mode = .regular, .name = "foo0", .oid = zero },
    };
    sort(&entries);
    try std.testing.expectEqualStrings("foo-bar", entries[0].name);
    try std.testing.expectEqualStrings("foo.txt", entries[1].name);
    try std.testing.expectEqualStrings("foo", entries[2].name);
    try std.testing.expectEqualStrings("foo0", entries[3].name);
}
