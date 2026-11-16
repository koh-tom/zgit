//! git の設定ファイルから、必要な値だけを読む。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const Repository = @import("Repository.zig");

/// `.git/config` → グローバル設定の順に `[section]` の `key` を探す。呼び出し側が free する
pub fn lookup(
    allocator: Allocator,
    repo: Repository,
    section: []const u8,
    key: []const u8,
) !?[]const u8 {
    if (try lookupInDir(allocator, repo.io, repo.git_dir, "config", section, key)) |v| return v;

    // グローバル設定。GIT_CONFIG_GLOBAL があればそれだけを見る (git と同じ)
    if (repo.env.get("GIT_CONFIG_GLOBAL")) |path| {
        return lookupInDir(allocator, repo.io, Dir.cwd(), path, section, key);
    }
    const home = repo.env.get("HOME") orelse return null;
    var home_dir = Dir.openDirAbsolute(repo.io, home, .{}) catch return null;
    defer home_dir.close(repo.io);
    if (try lookupInDir(allocator, repo.io, home_dir, ".gitconfig", section, key)) |v| return v;

    // XDG 配置の ~/.config/git/config も見る
    if (repo.env.get("XDG_CONFIG_HOME")) |xdg| {
        var xdg_dir = Dir.openDirAbsolute(repo.io, xdg, .{}) catch return null;
        defer xdg_dir.close(repo.io);
        return lookupInDir(allocator, repo.io, xdg_dir, "git/config", section, key);
    }
    return lookupInDir(allocator, repo.io, home_dir, ".config/git/config", section, key);
}

fn lookupInDir(
    allocator: Allocator,
    io: Io,
    dir: Dir,
    path: []const u8,
    section: []const u8,
    key: []const u8,
) !?[]const u8 {
    const result = dir.readFileAlloc(io, path, allocator, .limited(1 << 20));
    const text = result catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(text);
    const value = find(text, section, key) orelse return null;
    return try allocator.dupe(u8, value);
}

/// INI 風の中身から値を取り出す。`[user]` のあとに `name = value` が続く形だけを扱う
pub fn find(text: []const u8, section: []const u8, key: []const u8) ?[]const u8 {
    var in_section = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;

        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            in_section = std.ascii.eqlIgnoreCase(line[1..end], section);
            continue;
        }
        if (!in_section) continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const k = std.mem.trim(u8, line[0..eq], " \t");
        if (std.ascii.eqlIgnoreCase(k, key)) {
            return std.mem.trim(u8, line[eq + 1 ..], " \t\"");
        }
    }
    return null;
}

test "find values in a config file" {
    const text = "# comment\n" ++
        "[core]\n\tfilemode = true\n" ++
        "[user]\n\tname = Z Giter\n\temail = z@example.com\n" ++
        "[alias]\n\tname = not this one\n";
    try std.testing.expectEqualStrings("Z Giter", find(text, "user", "name").?);
    try std.testing.expectEqualStrings("z@example.com", find(text, "user", "email").?);
    try std.testing.expectEqualStrings("true", find(text, "core", "filemode").?);
    try std.testing.expectEqual(null, find(text, "user", "signingkey"));
    try std.testing.expectEqual(null, find(text, "remote", "url"));
}
