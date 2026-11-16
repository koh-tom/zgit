//! commit に書く作者と日時。環境変数 → git の設定ファイルの順に探す。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Repository = @import("Repository.zig");
const Commit = @import("Commit.zig");
const config = @import("config.zig");
const date = @import("date.zig");

pub const Role = enum { author, committer };

pub const Error = error{ MissingIdentity, InvalidDate };

/// GIT_AUTHOR_NAME などがあればそれを、無ければ user.name / user.email を使う。
/// 日時も GIT_AUTHOR_DATE があればそれを使う。git と同じ入力なら同じ commit ID になる。
/// 設定ファイルから読んだ文字列は確保したまま返す (CLI の arena が最後にまとめて解放する)
pub fn signature(
    allocator: Allocator,
    repo: Repository,
    comptime role: Role,
) !Commit.Signature {
    const prefix = switch (role) {
        .author => "GIT_AUTHOR_",
        .committer => "GIT_COMMITTER_",
    };
    const name = repo.env.get(prefix ++ "NAME") orelse
        try config.lookup(allocator, repo, "user", "name") orelse
        return error.MissingIdentity;
    const email = repo.env.get(prefix ++ "EMAIL") orelse
        try config.lookup(allocator, repo, "user", "email") orelse
        return error.MissingIdentity;
    const time = if (repo.env.get(prefix ++ "DATE")) |s|
        date.Time.parse(s) orelse return error.InvalidDate
    else
        date.now(repo.io, allocator);
    return .{ .name = name, .email = email, .time = time };
}
