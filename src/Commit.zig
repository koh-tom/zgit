//! commit オブジェクト。tree と親と作者を書いたテキストで、空行のあとにメッセージが続く。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Oid = @import("Oid.zig");
const Repository = @import("Repository.zig");
const odb = @import("odb.zig");
const Time = @import("date.zig").Time;

const Commit = @This();

tree: Oid,
/// 最初の commit は 0 個、merge commit は 2 個以上
parents: []const Oid,
author: Signature,
committer: Signature,
message: []const u8,

/// "Name <email> 1700000000 +0900"
pub const Signature = struct {
    name: []const u8,
    email: []const u8,
    time: Time,

    pub fn parse(s: []const u8) error{CorruptCommit}!Signature {
        const lt = std.mem.indexOfScalar(u8, s, '<') orelse return error.CorruptCommit;
        const gt = std.mem.indexOfScalarPos(u8, s, lt, '>') orelse return error.CorruptCommit;
        if (lt == 0 or gt + 2 > s.len) return error.CorruptCommit;
        return .{
            .name = s[0 .. lt - 1],
            .email = s[lt + 1 .. gt],
            .time = Time.parse(s[gt + 2 ..]) orelse return error.CorruptCommit,
        };
    }

    pub fn format(self: Signature, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s} <{s}> {f}", .{ self.name, self.email, self.time });
    }
};

pub const ParseError = error{ CorruptCommit, InvalidOid } || Allocator.Error;

/// `data` を解析する。name / email / message は `data` の中を指す。
/// parents だけ確保するので `deinit` が要る
pub fn parse(allocator: Allocator, data: []const u8) ParseError!Commit {
    var tree: ?Oid = null;
    var author: ?Signature = null;
    var committer: ?Signature = null;
    var parents: std.ArrayList(Oid) = .empty;
    errdefer parents.deinit(allocator);

    var rest = data;
    while (true) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return error.CorruptCommit;
        const line = rest[0..nl];
        rest = rest[nl + 1 ..];
        if (line.len == 0) break; // 空行から先はメッセージ

        // gpgsig などの複数行ヘッダは、2 行目以降が空白で始まる。読み飛ばす
        if (line[0] == ' ') continue;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse return error.CorruptCommit;
        const key = line[0..space];
        const value = line[space + 1 ..];

        if (std.mem.eql(u8, key, "tree")) {
            tree = try Oid.fromHex(value);
        } else if (std.mem.eql(u8, key, "parent")) {
            try parents.append(allocator, try Oid.fromHex(value));
        } else if (std.mem.eql(u8, key, "author")) {
            author = try Signature.parse(value);
        } else if (std.mem.eql(u8, key, "committer")) {
            committer = try Signature.parse(value);
        }
        // encoding や mergetag など、知らないヘッダは無視してよい
    }

    return .{
        .tree = tree orelse return error.CorruptCommit,
        .parents = try parents.toOwnedSlice(allocator),
        .author = author orelse return error.CorruptCommit,
        .committer = committer orelse return error.CorruptCommit,
        .message = rest,
    };
}

pub fn deinit(self: *Commit, allocator: Allocator) void {
    allocator.free(self.parents);
    self.* = undefined;
}

pub fn serialize(self: Commit, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("tree {f}\n", .{self.tree});
    for (self.parents) |p| try w.print("parent {f}\n", .{p});
    try w.print("author {f}\n", .{self.author});
    try w.print("committer {f}\n", .{self.committer});
    try w.writeByte('\n');
    try w.writeAll(self.message);
}

/// シリアライズしてオブジェクトとして保存し、ID を返す
pub fn write(self: Commit, allocator: Allocator, repo: Repository) !Oid {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try self.serialize(&buf.writer);
    return odb.write(repo, .commit, buf.written());
}

/// git は末尾に改行の無いメッセージに改行を足す。足したときだけ新しく確保する (arena 前提)
pub fn withNewline(allocator: Allocator, message: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, message, "\n")) return message;
    return std.mem.concat(allocator, u8, &.{ message, "\n" });
}

/// メッセージの 1 行目。log の要約表示に使う
pub fn summary(self: Commit) []const u8 {
    const end = std.mem.indexOfScalar(u8, self.message, '\n') orelse self.message.len;
    return self.message[0..end];
}

test "parse what git wrote" {
    const data =
        "tree d2f3d07c3315c88bc53c35daec28174a76ad33f6\n" ++
        "parent 975288f67061bb24209b45278574967599491617\n" ++
        "author Z Giter <z@example.com> 1700000000 +0900\n" ++
        "committer Z Giter <z@example.com> 1700000001 +0000\n" ++
        "\n" ++
        "second commit\n\nwith a body\n";

    var commit = try parse(std.testing.allocator, data);
    defer commit.deinit(std.testing.allocator);

    try std.testing.expectFmt("d2f3d07c3315c88bc53c35daec28174a76ad33f6", "{f}", .{commit.tree});
    try std.testing.expectEqual(1, commit.parents.len);
    try std.testing.expectEqualStrings("Z Giter", commit.author.name);
    try std.testing.expectEqualStrings("z@example.com", commit.author.email);
    try std.testing.expectEqual(1700000000, commit.author.time.secs);
    try std.testing.expectEqual(0, commit.committer.time.offset_min);
    try std.testing.expectEqualStrings("second commit", commit.summary());

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try commit.serialize(&out.writer);
    try std.testing.expectEqualStrings(data, out.written());
}

test "skips multi-line headers and tolerates no parent" {
    const data =
        "tree d2f3d07c3315c88bc53c35daec28174a76ad33f6\n" ++
        "author A <a@x> 1 +0000\n" ++
        "committer A <a@x> 1 +0000\n" ++
        "gpgsig -----BEGIN PGP SIGNATURE-----\n" ++
        " iQEzBAABCAAdFiEE\n" ++
        " -----END PGP SIGNATURE-----\n" ++
        "\n" ++
        "signed\n";
    var commit = try parse(std.testing.allocator, data);
    defer commit.deinit(std.testing.allocator);
    try std.testing.expectEqual(0, commit.parents.len);
    try std.testing.expectEqualStrings("signed\n", commit.message);

    try std.testing.expectError(error.CorruptCommit, parse(std.testing.allocator, "tree d2f3d07c3315c88bc53c35daec28174a76ad33f6\n"));
}
