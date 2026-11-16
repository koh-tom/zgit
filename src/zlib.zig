//! loose object を包む zlib ストリームの読み書き。中身は標準ライブラリの flate に任せる。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const flate = std.compress.flate;

pub const DecodeError = error{ Corrupt, ChecksumMismatch } || Allocator.Error;

/// zlib ストリームを全部展開する。返した buffer は呼び出し側が free する
pub fn decode(allocator: Allocator, compressed: []const u8) DecodeError![]u8 {
    if (compressed.len < 6) return error.Corrupt;

    var in: Io.Reader = .fixed(compressed);
    var window: [flate.max_window_len]u8 = undefined;
    var inflate: flate.Decompress = .init(&in, .zlib, &window);
    const out = inflate.reader.allocRemaining(allocator, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadFailed, error.StreamTooLong => return error.Corrupt,
    };
    errdefer allocator.free(out);

    // std は末尾の Adler-32 を読むだけで検証しないので、自分で確かめる
    const expected = std.mem.readInt(u32, compressed[compressed.len - 4 ..][0..4], .big);
    if (std.hash.Adler32.hash(out) != expected) return error.ChecksumMismatch;
    return out;
}

/// `parts` を順に繋げたものを zlib 圧縮して `w` に書く。
/// ヘッダと中身を別々のスライスのまま渡せるので、連結したバッファを作らずに済む。
/// `w` には 8 バイトより大きいバッファが必要 (flate の制約)
pub fn encode(w: *Io.Writer, parts: []const []const u8) Io.Writer.Error!void {
    var window: [flate.max_window_len]u8 = undefined;
    var deflate = try flate.Compress.init(w, &window, .zlib, .default);
    for (parts) |part| try deflate.writer.writeAll(part);
    try deflate.finish();
}

test "encode then decode" {
    const allocator = std.testing.allocator;
    const long: [70000]u8 = @splat('a');
    for ([_][]const u8{ "", "hello\n", &long }) |data| {
        var encoded: Io.Writer.Allocating = try .initCapacity(allocator, 4096);
        defer encoded.deinit();
        try encode(&encoded.writer, &.{ data[0 .. data.len / 2], data[data.len / 2 ..] });

        const decoded = try decode(allocator, encoded.written());
        defer allocator.free(decoded);
        try std.testing.expectEqualSlices(u8, data, decoded);
    }
}

test "decode what git wrote" {
    // $ printf 'hello\n' | git hash-object -w --stdin && xxd .git/objects/ce/0136...
    const from_git = [_]u8{
        0x78, 0x01, 0x4b, 0xca, 0xc9, 0x4f, 0x52, 0x30, 0x63, 0xc8, 0x48, 0xcd, 0xc9, 0xc9,
        0xe7, 0x02, 0x00, 0x1d, 0xc5, 0x04, 0x14,
    };
    const decoded = try decode(std.testing.allocator, &from_git);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("blob 6\x00hello\n", decoded);
}

test "detects a corrupted stream" {
    var broken = [_]u8{
        0x78, 0x01, 0x4b, 0xca, 0xc9, 0x4f, 0x52, 0x30, 0x63, 0xc8, 0x48, 0xcd, 0xc9, 0xc9,
        0xe7, 0x02, 0x00, 0x1d, 0xc5, 0x04, 0x15,
    };
    try std.testing.expectError(error.ChecksumMismatch, decode(std.testing.allocator, &broken));
    broken[0] = 0;
    try std.testing.expectError(error.Corrupt, decode(std.testing.allocator, &broken));
}
