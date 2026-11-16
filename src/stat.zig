//! index に入れるための stat。`std.Io.Dir.statFile` には dev / uid / gid が無いので、
//! ここだけ OS の stat を直接呼ぶ。シンボリックリンクは辿らない (lstat)。

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Dir = std.Io.Dir;

pub const Stat = struct {
    dev: u64,
    ino: u64,
    /// 種類とパーミッション。S.IFMT でマスクすると種類が分かる
    mode: u32,
    uid: u32,
    gid: u32,
    size: u64,
    ctime_sec: i64,
    ctime_nsec: u32,
    mtime_sec: i64,
    mtime_nsec: u32,

    pub fn isDir(self: Stat) bool {
        return self.mode & posix.S.IFMT == posix.S.IFDIR;
    }

    pub fn isSymlink(self: Stat) bool {
        return self.mode & posix.S.IFMT == posix.S.IFLNK;
    }

    pub fn isExecutable(self: Stat) bool {
        return self.mode & 0o100 != 0;
    }
};

pub const Error = error{ FileNotFound, NameTooLong } || posix.UnexpectedError;

/// `dir` から見た `path` を lstat する。無ければ error.FileNotFound
pub fn lstat(dir: Dir, path: []const u8) Error!Stat {
    const path_z = try posix.toPosixPath(if (path.len == 0) "." else path);
    return switch (builtin.os.tag) {
        .linux => lstatLinux(dir, &path_z),
        else => lstatPosix(dir, &path_z),
    };
}

// Linux には statx があり、libc 無しで呼べる
fn lstatLinux(dir: Dir, path_z: [*:0]const u8) Error!Stat {
    const linux = std.os.linux;
    var stx = std.mem.zeroes(linux.Statx);
    const want: linux.STATX = .{
        .TYPE = true,
        .MODE = true,
        .UID = true,
        .GID = true,
        .INO = true,
        .SIZE = true,
        .MTIME = true,
        .CTIME = true,
    };
    const rc = linux.statx(dir.handle, path_z, linux.AT.SYMLINK_NOFOLLOW, want, &stx);
    return switch (linux.errno(rc)) {
        .SUCCESS => .{
            .dev = makedev(stx.dev_major, stx.dev_minor),
            .ino = stx.ino,
            .mode = stx.mode,
            .uid = stx.uid,
            .gid = stx.gid,
            .size = stx.size,
            .ctime_sec = stx.ctime.sec,
            .ctime_nsec = stx.ctime.nsec,
            .mtime_sec = stx.mtime.sec,
            .mtime_nsec = stx.mtime.nsec,
        },
        .NOENT, .NOTDIR => error.FileNotFound,
        else => |e| posix.unexpectedErrno(e),
    };
}

/// statx は major と minor を別々に返す。glibc の makedev() と同じ詰め方で st_dev の値に戻す
fn makedev(major: u64, minor: u64) u64 {
    return (major & 0xfffff000) << 32 | (major & 0xfff) << 8 |
        (minor & 0xffffff00) << 12 | (minor & 0xff);
}

// Linux 以外は libc の fstatat。参考実装で、動作は確かめていない
fn lstatPosix(dir: Dir, path_z: [*:0]const u8) Error!Stat {
    const c = std.c;
    var st: c.Stat = undefined;
    return switch (posix.errno(c.fstatat(dir.handle, path_z, &st, c.AT.SYMLINK_NOFOLLOW))) {
        .SUCCESS => .{
            .dev = @bitCast(@as(i64, st.dev)),
            .ino = st.ino,
            .mode = st.mode,
            .uid = st.uid,
            .gid = st.gid,
            .size = @intCast(st.size),
            .ctime_sec = st.ctime().sec,
            .ctime_nsec = @intCast(st.ctime().nsec),
            .mtime_sec = st.mtime().sec,
            .mtime_nsec = @intCast(st.mtime().nsec),
        },
        .NOENT, .NOTDIR => error.FileNotFound,
        else => |e| posix.unexpectedErrno(e),
    };
}

test "lstat does not follow symlinks" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello\n" });
    try tmp.dir.symLink(io, "a.txt", "link", .{});
    try tmp.dir.createDirPath(io, "sub");

    const file = try lstat(tmp.dir, "a.txt");
    try std.testing.expectEqual(6, file.size);
    try std.testing.expect(!file.isDir() and !file.isSymlink());
    try std.testing.expect((try lstat(tmp.dir, "link")).isSymlink());
    try std.testing.expect((try lstat(tmp.dir, "sub")).isDir());
    try std.testing.expect((try lstat(tmp.dir, "")).isDir());
    try std.testing.expectError(error.FileNotFound, lstat(tmp.dir, "nope"));
}
