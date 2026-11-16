//! index (staging area)。`.git/index` は「次の commit に入るファイルの一覧」をバイナリで持つ。
//! 各 entry には blob の ID のほかに stat の結果が入っていて、
//! 作業ツリーのファイルが変わっていないかを中身を読まずに判定するのに使う。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Repository = @import("Repository.zig");
const Oid = @import("Oid.zig");
const Tree = @import("Tree.zig");
const odb = @import("odb.zig");
const Stat = @import("stat.zig").Stat;

const Index = @This();

const signature = "DIRC";
const version: u32 = 2;
/// path より前の固定部分の長さ
const entry_fixed_len = 62;

entries: std.ArrayList(Entry),
/// 読んだファイルの version。書くときは常に 2
file_version: u32 = version,
/// 読み飛ばした拡張。inspect で見せるためだけに覚えておく
extensions: std.ArrayList(Extension) = .empty,
/// path 文字列の置き場。読んだものと add で作ったものが混ざるので、寿命を一つにまとめる
arena: std.heap.ArenaAllocator,

pub const Entry = struct {
    ctime_sec: u32,
    ctime_nsec: u32,
    mtime_sec: u32,
    mtime_nsec: u32,
    dev: u32,
    ino: u32,
    mode: u32,
    uid: u32,
    gid: u32,
    size: u32,
    oid: Oid,
    /// 上位 4 ビットがフラグ (assume-valid, extended, stage×2)、下位 12 ビットが path の長さ
    flags: u16,
    path: []const u8,

    pub const flag_extended: u16 = 0x4000;
    pub const name_mask: u16 = 0x0fff;

    pub fn stage(self: Entry) u2 {
        return @truncate(self.flags >> 12);
    }

    /// 作業ツリーのファイルの stat 結果から作る。mode は git が区別する 3 種類に丸める
    pub fn fromStat(path: []const u8, st: Stat, oid: Oid) Entry {
        const mode: u32 = if (st.isSymlink())
            0o120000
        else if (st.isExecutable())
            0o100755
        else
            0o100644;
        return .{
            .ctime_sec = low32(@bitCast(st.ctime_sec)),
            .ctime_nsec = st.ctime_nsec,
            .mtime_sec = low32(@bitCast(st.mtime_sec)),
            .mtime_nsec = st.mtime_nsec,
            .dev = low32(st.dev),
            .ino = low32(st.ino),
            .mode = mode,
            .uid = st.uid,
            .gid = st.gid,
            .size = low32(st.size),
            .oid = oid,
            .flags = @intCast(@min(path.len, name_mask)),
            .path = path,
        };
    }
};

/// stat の値は 64 ビットだが、index には下位 32 ビットだけ入る (git も同じ)
fn low32(x: u64) u32 {
    return @truncate(x);
}

pub const Extension = struct {
    signature: [4]u8,
    size: u32,
};

pub const Error = error{ CorruptIndex, UnsupportedIndexVersion, ChecksumMismatch };

pub fn init(allocator: Allocator) Index {
    return .{ .entries = .empty, .arena = std.heap.ArenaAllocator.init(allocator) };
}

pub fn deinit(self: *Index) void {
    self.entries.deinit(self.arena.child_allocator);
    self.extensions.deinit(self.arena.child_allocator);
    self.arena.deinit();
    self.* = undefined;
}

/// `.git/index` を読む。まだ無ければ空の index
pub fn read(allocator: Allocator, repo: Repository) !Index {
    var index = init(allocator);
    errdefer index.deinit();

    const buf = (try repo.readFile(index.arena.allocator(), "index")) orelse return index;
    try index.parse(buf);
    return index;
}

/// バイト列を解析する。path は `buf` の中を指す
pub fn parse(self: *Index, buf: []const u8) !void {
    if (buf.len < 12 + Oid.len) return error.CorruptIndex;

    // 末尾 20 バイトは、それより前の全体の SHA-1
    const body = buf[0 .. buf.len - Oid.len];
    var expected: [Oid.len]u8 = undefined;
    std.crypto.hash.Sha1.hash(body, &expected, .{});
    if (!std.mem.eql(u8, &expected, buf[body.len..])) return error.ChecksumMismatch;

    var r: std.Io.Reader = .fixed(body);
    if (!std.mem.eql(u8, try r.take(4), signature)) return error.CorruptIndex;
    self.file_version = try r.takeInt(u32, .big);
    if (self.file_version != 2 and self.file_version != 3) return error.UnsupportedIndexVersion;
    const count = try r.takeInt(u32, .big);

    try self.entries.ensureTotalCapacity(self.arena.child_allocator, count);
    for (0..count) |_| {
        const start = r.seek;
        var e: Entry = undefined;
        e.ctime_sec = try r.takeInt(u32, .big);
        e.ctime_nsec = try r.takeInt(u32, .big);
        e.mtime_sec = try r.takeInt(u32, .big);
        e.mtime_nsec = try r.takeInt(u32, .big);
        e.dev = try r.takeInt(u32, .big);
        e.ino = try r.takeInt(u32, .big);
        e.mode = try r.takeInt(u32, .big);
        e.uid = try r.takeInt(u32, .big);
        e.gid = try r.takeInt(u32, .big);
        e.size = try r.takeInt(u32, .big);
        e.oid = Oid.fromBytes(try r.takeArray(Oid.len));
        e.flags = try r.takeInt(u16, .big);
        // version 3 の拡張フラグ (intent-to-add など) は読み飛ばす
        if (e.flags & Entry.flag_extended != 0) {
            _ = try r.takeInt(u16, .big);
            e.flags &= ~Entry.flag_extended;
        }
        e.path = try r.takeSentinel(0);

        // entry 全体が 8 の倍数になるよう NUL で埋められている
        const used = r.seek - start;
        try r.discardAll((8 - used % 8) % 8);
        self.entries.appendAssumeCapacity(e);
    }
    // 以降は拡張 (TREE など)。署名と長さだけ控えて中身は読み飛ばす
    while (r.seek < body.len) {
        const ext = Extension{
            .signature = (try r.takeArray(4)).*,
            .size = try r.takeInt(u32, .big),
        };
        try r.discardAll(ext.size);
        try self.extensions.append(self.arena.child_allocator, ext);
    }
}

/// `.git/index` に書く。index.lock に書いてから rename するので、途中で止まっても index は壊れない
pub fn write(self: *Index, repo: Repository) !void {
    self.sort();

    var out: std.Io.Writer.Allocating = .init(self.arena.child_allocator);
    defer out.deinit();
    const w = &out.writer;

    try w.writeAll(signature);
    try w.writeInt(u32, version, .big);
    try w.writeInt(u32, @intCast(self.entries.items.len), .big);
    for (self.entries.items) |e| {
        const stat_fields = [_]u32{
            e.ctime_sec, e.ctime_nsec, e.mtime_sec, e.mtime_nsec,
            e.dev,       e.ino,        e.mode,      e.uid,
            e.gid,       e.size,
        };
        for (stat_fields) |v| {
            try w.writeInt(u32, v, .big);
        }
        try w.writeAll(&e.oid.bytes);
        try w.writeInt(u16, e.flags, .big);
        try w.writeAll(e.path);
        const used = entry_fixed_len + e.path.len;
        try w.splatByteAll(0, 8 - used % 8);
    }

    var checksum: [Oid.len]u8 = undefined;
    std.crypto.hash.Sha1.hash(out.written(), &checksum, .{});
    try w.writeAll(&checksum);

    const created = repo.git_dir.createFile(repo.io, "index.lock", .{ .exclusive = true });
    const lock = created catch |err| switch (err) {
        error.PathAlreadyExists => return error.IndexLocked,
        else => return err,
    };
    errdefer repo.git_dir.deleteFile(repo.io, "index.lock") catch {};
    {
        defer lock.close(repo.io);
        try lock.writeStreamingAll(repo.io, out.written());
    }
    try repo.git_dir.rename("index.lock", repo.git_dir, "index", repo.io);
}

/// 同じ path があれば置き換え、無ければ追加する。path はコピーして持つ
pub fn add(self: *Index, entry: Entry) !void {
    self.removeConflicts(entry.path);
    var copy = entry;
    copy.path = try self.arena.allocator().dupe(u8, entry.path);
    if (self.find(entry.path)) |existing| {
        existing.* = copy;
    } else {
        try self.entries.append(self.arena.child_allocator, copy);
    }
}

/// ファイルとディレクトリは同じ名前で同居できない。foo を足すなら foo/bar は外し、逆も同じ
fn removeConflicts(self: *Index, path: []const u8) void {
    var i: usize = 0;
    while (i < self.entries.items.len) {
        const other = self.entries.items[i].path;
        if (isUnder(other, path) or isUnder(path, other)) {
            _ = self.entries.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

pub fn remove(self: *Index, path: []const u8) bool {
    for (self.entries.items, 0..) |e, i| {
        if (std.mem.eql(u8, e.path, path)) {
            _ = self.entries.orderedRemove(i);
            return true;
        }
    }
    return false;
}

pub fn find(self: *Index, path: []const u8) ?*Entry {
    for (self.entries.items) |*e| {
        if (std.mem.eql(u8, e.path, path)) return e;
    }
    return null;
}

/// 平らな一覧から入れ子の tree を作って保存し、ルートの tree の ID を返す。git write-tree 相当
pub fn writeTree(self: *Index, repo: Repository) !Oid {
    self.sort();
    return writeSubtree(self.arena.child_allocator, repo, self.entries.items, 0);
}

/// `entries` は全部同じディレクトリの下。path の先頭 `prefix_len` バイトがそのディレクトリ名
fn writeSubtree(
    allocator: Allocator,
    repo: Repository,
    entries: []const Entry,
    prefix_len: usize,
) !Oid {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var children: std.ArrayList(Tree.Entry) = .empty;

    var i: usize = 0;
    while (i < entries.len) {
        const rest = entries[i].path[prefix_len..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            // サブディレクトリ。同じ名前で始まる entry は並んでいるので、まとめて再帰する
            const name = rest[0..slash];
            var j = i + 1;
            while (j < entries.len and isUnder(entries[j].path[prefix_len..], name)) j += 1;
            const sub_prefix = prefix_len + slash + 1;
            const oid = try writeSubtree(allocator, repo, entries[i..j], sub_prefix);
            try children.append(scratch, .{ .mode = .directory, .name = name, .oid = oid });
            i = j;
        } else {
            const mode = std.enums.fromInt(Tree.Mode, entries[i].mode) orelse
                return error.CorruptIndex;
            const oid = entries[i].oid;
            try children.append(scratch, .{ .mode = mode, .name = rest, .oid = oid });
            i += 1;
        }
    }

    Tree.sort(children.items);
    var out: std.Io.Writer.Allocating = .init(scratch);
    try (Tree{ .entries = children.items }).serialize(&out.writer);
    return odb.write(repo, .tree, out.written());
}

fn isUnder(path: []const u8, dir: []const u8) bool {
    return path.len > dir.len and std.mem.startsWith(u8, path, dir) and path[dir.len] == '/';
}

/// path のバイト順。tree の順序とは違い、ディレクトリの区切りを特別扱いしない
fn sort(self: *Index) void {
    std.mem.sort(Entry, self.entries.items, {}, lessThan);
}

fn lessThan(_: void, a: Entry, b: Entry) bool {
    return switch (std.mem.order(u8, a.path, b.path)) {
        .lt => true,
        .gt => false,
        .eq => a.stage() < b.stage(),
    };
}

// $ git add hello.txt src/main.zig && xxd .git/index
const from_git = [_]u8{
    0x44, 0x49, 0x52, 0x43, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x6a, 0xed, 0x89, 0x30,
    0x3a, 0xc4, 0x4b, 0x49, 0x6a, 0xed, 0x89, 0x30, 0x3a, 0xc4, 0x4b, 0x49, 0x00, 0x00, 0x00, 0x3e,
    0x00, 0x00, 0x22, 0xeb, 0x00, 0x00, 0x81, 0xa4, 0x00, 0x00, 0x03, 0xe8, 0x00, 0x00, 0x03, 0xe8,
    0x00, 0x00, 0x00, 0x06, 0xce, 0x01, 0x36, 0x25, 0x03, 0x0b, 0xa8, 0xdb, 0xa9, 0x06, 0xf7, 0x56,
    0x96, 0x7f, 0x9e, 0x9c, 0xa3, 0x94, 0x46, 0x4a, 0x00, 0x09, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x2e,
    0x74, 0x78, 0x74, 0x00, 0x6a, 0xed, 0x89, 0x31, 0x00, 0x2c, 0xe6, 0xfe, 0x6a, 0xed, 0x89, 0x31,
    0x00, 0x2c, 0xe6, 0xfe, 0x00, 0x00, 0x00, 0x3e, 0x00, 0x00, 0x22, 0xef, 0x00, 0x00, 0x81, 0xa4,
    0x00, 0x00, 0x03, 0xe8, 0x00, 0x00, 0x03, 0xe8, 0x00, 0x00, 0x00, 0x0d, 0x94, 0x3c, 0x45, 0x8c,
    0x79, 0xe2, 0x0e, 0xb2, 0x48, 0xd0, 0xa3, 0x86, 0x35, 0xd1, 0xdb, 0x9f, 0xc6, 0x51, 0x08, 0x57,
    0x00, 0x0c, 0x73, 0x72, 0x63, 0x2f, 0x6d, 0x61, 0x69, 0x6e, 0x2e, 0x7a, 0x69, 0x67, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x3f, 0xc1, 0xb8, 0xea, 0xc5, 0x81, 0x63, 0x00, 0x3c, 0x99, 0x23, 0xfc,
    0xfc, 0x6a, 0x9d, 0xa4, 0xf8, 0xa0, 0xd4, 0xfb,
};

test "parse what git wrote" {
    var index = init(std.testing.allocator);
    defer index.deinit();
    try index.parse(&from_git);

    try std.testing.expectEqual(2, index.entries.items.len);
    const hello = index.entries.items[0];
    try std.testing.expectEqualStrings("hello.txt", hello.path);
    try std.testing.expectEqual(0o100644, hello.mode);
    try std.testing.expectEqual(6, hello.size);
    try std.testing.expectEqual(1793952048, hello.ctime_sec);
    try std.testing.expectEqual(985942857, hello.ctime_nsec);
    try std.testing.expectEqual(62, hello.dev);
    try std.testing.expectEqual(0, hello.stage());
    try std.testing.expectFmt("ce013625030ba8dba906f756967f9e9ca394464a", "{f}", .{hello.oid});
    try std.testing.expectEqualStrings("src/main.zig", index.entries.items[1].path);
}

test "write reproduces git's bytes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var repo = try Repository.initForTest(allocator, tmp);
    defer repo.close(allocator);

    var index = init(allocator);
    defer index.deinit();
    try index.parse(&from_git);
    // 逆順に足しても、書くときに並び直す
    var reordered = init(allocator);
    defer reordered.deinit();
    try reordered.add(index.entries.items[1]);
    try reordered.add(index.entries.items[0]);
    try reordered.write(repo);

    const written = (try repo.readFile(allocator, "index")).?;
    defer allocator.free(written);
    try std.testing.expectEqualSlices(u8, &from_git, written);

    var again = try read(allocator, repo);
    defer again.deinit();
    try std.testing.expectEqual(2, again.entries.items.len);
    try std.testing.expect(again.remove("hello.txt"));
    try std.testing.expect(!again.remove("hello.txt"));
}

test "write-tree builds nested trees" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var repo = try Repository.initForTest(allocator, tmp);
    defer repo.close(allocator);

    var index = init(allocator);
    defer index.deinit();
    try index.parse(&from_git);
    // $ git write-tree  (hello.txt と src/main.zig)
    try std.testing.expectFmt("d2f3d07c3315c88bc53c35daec28174a76ad33f6", "{f}", .{try index.writeTree(repo)});

    var empty = init(allocator);
    defer empty.deinit();
    try std.testing.expectFmt("4b825dc642cb6eb9a060e54bf8d69288fbee4904", "{f}", .{try empty.writeTree(repo)});
}

test "rejects a damaged file" {
    var damaged = from_git;
    damaged[20] ^= 1;
    var index = init(std.testing.allocator);
    defer index.deinit();
    try std.testing.expectError(error.ChecksumMismatch, index.parse(&damaged));
}
