//! コマンド層で共有する小物。

const std = @import("std");
const Repository = @import("Repository.zig");

/// どのサブコマンドにも必要なもの一式。main が用意して run に渡す
pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// 標準出力。main がバッファ付きの writer を用意する
    out: *std.Io.Writer,
    /// 環境変数。GIT_AUTHOR_NAME や HOME を読む
    env: *const std.process.Environ.Map,

    /// カレントディレクトリから上に辿ってリポジトリを開く
    pub fn openRepo(ctx: Context) !Repository {
        return Repository.discover(ctx.allocator, ctx.io, ctx.env, ".");
    }
};

/// git の die() 相当。メッセージを出して error.Fatal を返す。main が exit code 128 にする
pub fn fatal(comptime fmt: []const u8, args: anytype) error{Fatal} {
    std.debug.print("fatal: " ++ fmt ++ "\n", args);
    return error.Fatal;
}
