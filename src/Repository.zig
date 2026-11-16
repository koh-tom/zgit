//! リポジトリの場所。`.git` と作業ツリーの 2 つのディレクトリを持つ。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;

const Repository = @This();

/// ファイル操作に使う。Zig 0.17 では allocator と同じく、入出力も引数で受け取る
io: Io,
/// 環境変数。作者名や設定ファイルの場所を探すのに使う
env: *const std.process.Environ.Map,
/// 作業ツリーの絶対パス。close() で解放する
work_path: []const u8,
work_dir: Dir,
git_dir: Dir,

/// `path` に空のリポジトリを作る。既にあるファイルは上書きしない
pub fn init(io: Io, path: []const u8) !void {
    var root = try Dir.cwd().createDirPathOpen(io, path, .{});
    defer root.close(io);
    var git = try root.createDirPathOpen(io, ".git", .{});
    defer git.close(io);

    try git.createDirPath(io, "objects/info");
    try git.createDirPath(io, "objects/pack");
    try git.createDirPath(io, "refs/heads");
    try git.createDirPath(io, "refs/tags");

    try writeIfAbsent(io, git, "HEAD", "ref: refs/heads/main\n");
    try writeIfAbsent(io, git, "config", "[core]\n" ++
        "\trepositoryformatversion = 0\n" ++
        "\tfilemode = true\n" ++
        "\tbare = false\n" ++
        "\tlogallrefupdates = true\n");
    try writeIfAbsent(io, git, "description", "Unnamed repository; edit this file " ++
        "'description' to name the repository.\n");
}

fn writeIfAbsent(io: Io, dir: Dir, name: []const u8, data: []const u8) !void {
    const file = dir.createFile(io, name, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => return err,
    };
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

/// `start` から親ディレクトリへ向かって `.git` を探す。git が cwd から探すのと同じ
pub fn discover(
    allocator: Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    start: []const u8,
) !Repository {
    const abs = try Dir.cwd().realPathFileAlloc(io, start, allocator);
    defer allocator.free(abs);

    var path: []const u8 = abs;
    while (true) {
        if (openAt(allocator, io, env, path)) |repo| {
            return repo;
        } else |err| switch (err) {
            error.NotARepository => {},
            else => return err,
        }
        path = Dir.path.dirname(path) orelse return error.NotARepository;
    }
}

/// `path` 直下に `.git` があればそこを開く
fn openAt(
    allocator: Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    path: []const u8,
) !Repository {
    var work_dir = try Dir.openDirAbsolute(io, path, .{});
    errdefer work_dir.close(io);

    var git_dir = work_dir.openDir(io, ".git", .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.NotARepository,
        else => return err,
    };
    errdefer git_dir.close(io);

    return .{
        .io = io,
        .env = env,
        .work_path = try allocator.dupe(u8, path),
        .work_dir = work_dir,
        .git_dir = git_dir,
    };
}

/// `.git` の下のファイルを丸ごと読む。無ければ null。返した buffer は呼び出し側が free する
pub fn readFile(self: Repository, allocator: Allocator, path: []const u8) !?[]u8 {
    const result = self.git_dir.readFileAlloc(self.io, path, allocator, .limited(1 << 30));
    return result catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

pub fn close(self: *Repository, allocator: Allocator) void {
    self.git_dir.close(self.io);
    self.work_dir.close(self.io);
    allocator.free(self.work_path);
    self.* = undefined;
}

/// テスト用。一時ディレクトリにリポジトリを作って開く
pub fn initForTest(allocator: Allocator, tmp: std.testing.TmpDir) !Repository {
    const io = std.testing.io;
    const base = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    try init(io, base);
    return discover(allocator, io, &test_env, base);
}

var test_env: std.process.Environ.Map = .init(std.testing.allocator);

test "init creates the layout git expects" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var repo = try initForTest(allocator, tmp);
    defer repo.close(allocator);

    var head_buf: [64]u8 = undefined;
    const head = try repo.git_dir.readFile(io, "HEAD", &head_buf);
    try std.testing.expectEqualStrings("ref: refs/heads/main\n", head);

    // 二度目の init で HEAD を壊さない
    try repo.git_dir.writeFile(io, .{ .sub_path = "HEAD", .data = "ref: refs/heads/dev\n" });
    try init(io, repo.work_path);
    const again = try repo.git_dir.readFile(io, "HEAD", &head_buf);
    try std.testing.expectEqualStrings("ref: refs/heads/dev\n", again);
}

test "discover walks up from a subdirectory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var repo = try initForTest(allocator, tmp);
    defer repo.close(allocator);
    try repo.work_dir.createDirPath(io, "src/deep");

    const nested = try Dir.path.join(allocator, &.{ repo.work_path, "src", "deep" });
    defer allocator.free(nested);
    var found = try discover(allocator, io, &test_env, nested);
    defer found.close(allocator);
    try std.testing.expectEqualStrings(repo.work_path, found.work_path);
}
