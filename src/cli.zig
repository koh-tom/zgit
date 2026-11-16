//! コマンド層で共有する小物。

const std = @import("std");

/// どのサブコマンドにも必要なもの一式。main が用意して run に渡す
pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// 標準出力。main がバッファ付きの writer を用意する
    out: *std.Io.Writer,
    /// 環境変数。GIT_AUTHOR_NAME や HOME を読む
    env: *const std.process.Environ.Map,
};
