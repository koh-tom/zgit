//! Object Database。`.git/objects/xx/yyyy...` に置かれた loose object の読み書き。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Repository = @import("Repository.zig");
const Oid = @import("Oid.zig");
const object = @import("object.zig");
const zlib = @import("zlib.zig");

pub const Error = error{
    ObjectNotFound,
    CorruptObject,
    UnknownObjectType,
    AmbiguousObject,
};

/// 読み込んだオブジェクト。`body` は `buf` の中を指しているので、free は `buf` に対して一度だけ
pub const Loaded = struct {
    kind: object.Type,
    buf: []u8,
    body: []const u8,

    pub fn deinit(self: Loaded, allocator: Allocator) void {
        allocator.free(self.buf);
    }
};

/// `oid` のオブジェクトを展開して返す。呼び出し側が `deinit` する
pub fn read(allocator: Allocator, repo: Repository, oid: Oid) !Loaded {
    var path_buf: [64]u8 = undefined;
    const path = objectPath(&path_buf, oid);

    const compressed = (try repo.readFile(allocator, path)) orelse return error.ObjectNotFound;
    defer allocator.free(compressed);

    const buf = zlib.decode(allocator, compressed) catch |err| switch (err) {
        error.Corrupt, error.ChecksumMismatch => return error.CorruptObject,
        error.OutOfMemory => return error.OutOfMemory,
    };
    errdefer allocator.free(buf);

    const header = try object.parseHeader(buf);
    const body = buf[header.header_len..];
    if (body.len != header.size) return error.CorruptObject;

    return .{ .kind = header.kind, .buf = buf, .body = body };
}

/// オブジェクトを保存して ID を返す。同じ内容は一度しか書かれない
pub fn write(repo: Repository, kind: object.Type, data: []const u8) !Oid {
    const oid = object.hash(kind, data);
    if (exists(repo, oid)) return oid;

    var path_buf: [64]u8 = undefined;
    const path = objectPath(&path_buf, oid);

    // 書きかけを他のプロセスに見せないよう、名無しの一時ファイルに書いてから名前を付ける。
    // git と同じく、出来上がったオブジェクトは読み取り専用にしておく
    var atomic = try repo.git_dir.createFileAtomic(repo.io, path, .{
        .permissions = .fromMode(0o444),
        .make_path = true,
    });
    defer atomic.deinit(repo.io);

    var write_buf: [8192]u8 = undefined;
    var file_writer: Io.File.Writer = .init(atomic.file, repo.io, &write_buf);
    var header_buf: [32]u8 = undefined;
    var header: Io.Writer = .fixed(&header_buf);
    try object.writeHeader(&header, kind, data.len);
    try zlib.encode(&file_writer.interface, &.{ header.buffered(), data });
    try file_writer.interface.flush();

    atomic.link(repo.io) catch |err| switch (err) {
        // 同時に同じオブジェクトを書いた相手がいただけ。中身は同じなので問題ない
        error.PathAlreadyExists => {},
        else => return err,
    };
    return oid;
}

pub fn exists(repo: Repository, oid: Oid) bool {
    var path_buf: [64]u8 = undefined;
    repo.git_dir.access(repo.io, objectPath(&path_buf, oid), .{}) catch return false;
    return true;
}

/// 短縮 ID から探す。"ce01" なら objects/ce/ の中で "01" で始まるものを数える
pub fn findByPrefix(repo: Repository, prefix: []const u8) !?Oid {
    if (prefix.len < 4 or prefix.len > Oid.hex_len) return null;

    var dir_buf: ["objects/xx".len]u8 = undefined;
    const dir_path =
        std.fmt.bufPrint(&dir_buf, "objects/{s}", .{prefix[0..2]}) catch unreachable;
    const opened = repo.git_dir.openDir(repo.io, dir_path, .{ .iterate = true });
    var dir = opened catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(repo.io);

    var found: ?Oid = null;
    var it = dir.iterate();
    while (try it.next(repo.io)) |entry| {
        // オブジェクト以外のファイル (一時ファイルなど) は長さが違うので飛ばす
        if (entry.name.len != Oid.hex_len - 2) continue;
        if (!std.mem.startsWith(u8, entry.name, prefix[2..])) continue;
        if (found != null) return error.AmbiguousObject;
        var hex: [Oid.hex_len]u8 = undefined;
        @memcpy(hex[0..2], prefix[0..2]);
        @memcpy(hex[2..], entry.name);
        found = Oid.fromHex(&hex) catch continue;
    }
    return found;
}

/// "objects/ce/013625030ba8dba906f756967f9e9ca394464a" の形にする
fn objectPath(buf: *[64]u8, oid: Oid) []const u8 {
    const hex = oid.toHex();
    return std.fmt.bufPrint(buf, "objects/{s}/{s}", .{ hex[0..2], hex[2..] }) catch unreachable;
}

test "write then read" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var repo = try Repository.initForTest(allocator, tmp);
    defer repo.close(allocator);

    const oid = try write(repo, .blob, "hello\n");
    try std.testing.expectFmt("ce013625030ba8dba906f756967f9e9ca394464a", "{f}", .{oid});
    try std.testing.expect(exists(repo, oid));

    const loaded = try read(allocator, repo, oid);
    defer loaded.deinit(allocator);
    try std.testing.expectEqual(object.Type.blob, loaded.kind);
    try std.testing.expectEqualStrings("hello\n", loaded.body);

    // 二度書いても壊れない (読み取り専用ファイルを上書きしようとしない)
    _ = try write(repo, .blob, "hello\n");

    try std.testing.expect(oid.eql((try findByPrefix(repo, "ce0136")).?));
    try std.testing.expectEqual(null, try findByPrefix(repo, "ffff"));

    const missing = Oid.fromHex("0000000000000000000000000000000000000000") catch unreachable;
    try std.testing.expectError(error.ObjectNotFound, read(allocator, repo, missing));
}
