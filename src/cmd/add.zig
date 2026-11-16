const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("../cli.zig");
const Repository = @import("../Repository.zig");
const Index = @import("../Index.zig");
const odb = @import("../odb.zig");
const worktree = @import("../worktree.zig");

pub const usage = "zgit add <path>...";

pub fn run(ctx: cli.Context, args: []const []const u8) !void {
    if (args.len == 0) return error.Usage;
    const allocator = ctx.allocator;

    var repo = try ctx.openRepo();
    defer repo.close(allocator);
    var index = try Index.read(allocator, repo);
    defer index.deinit();

    for (args) |arg| {
        const path = worktree.normalize(allocator, repo, arg) catch |err| switch (err) {
            error.OutsideRepository => return cli.fatal("'{s}' is outside repository", .{arg}),
            else => return err,
        };
        defer allocator.free(path);

        const st = worktree.lstat(repo, path) catch |err| switch (err) {
            error.FileNotFound => {
                // 消えたファイルを add すると index からも消える (git と同じ)
                if (index.remove(path)) continue;
                return cli.fatal("pathspec '{s}' did not match any files", .{arg});
            },
            else => return err,
        };

        if (st.isDir()) {
            try addDirectory(allocator, repo, &index, path);
        } else {
            try addFile(allocator, repo, &index, path);
        }
    }
    try index.write(repo);
}

/// blob を書き、stat 情報と一緒に index に載せる
fn addFile(allocator: Allocator, repo: Repository, index: *Index, path: []const u8) !void {
    const st = try worktree.lstat(repo, path);
    const data = try worktree.readFile(allocator, repo, path, st);
    defer allocator.free(data);
    const oid = try odb.write(repo, .blob, data);
    try index.add(Index.Entry.fromStat(path, st, oid));
}

/// ディレクトリの下を全部。index にあって作業ツリーに無いものは外す
fn addDirectory(
    allocator: Allocator,
    repo: Repository,
    index: *Index,
    dir: []const u8,
) !void {
    const files = try worktree.listFiles(allocator, repo, dir);
    defer worktree.freeFiles(allocator, files);
    for (files) |path| try addFile(allocator, repo, index, path);

    var i: usize = 0;
    while (i < index.entries.items.len) {
        const path = index.entries.items[i].path;
        if (worktree.contains(dir, path) and !worktree.exists(repo, path)) {
            _ = index.remove(path);
        } else {
            i += 1;
        }
    }
}
