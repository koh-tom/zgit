//! commit に書く日時。git は「UNIX 時刻 + タイムゾーンのオフセット」の組で持つ。

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Time = struct {
    /// 1970-01-01 00:00:00 UTC からの秒数
    secs: i64,
    /// UTC からのずれ (分)。+0900 なら 540
    offset_min: i16,

    /// "1700000000 +0900" の形。git が GIT_AUTHOR_DATE などで受け付ける内部表記
    pub fn parse(s: []const u8) ?Time {
        const trimmed = std.mem.trim(u8, s, " \t\n");
        var it = std.mem.splitScalar(u8, trimmed, ' ');
        var secs_str = it.next() orelse return null;
        if (std.mem.startsWith(u8, secs_str, "@")) secs_str = secs_str[1..];
        const secs = std.fmt.parseInt(i64, secs_str, 10) catch return null;
        const offset_min = parseOffset(it.next() orelse return null) orelse return null;
        return .{ .secs = secs, .offset_min = offset_min };
    }

    /// "+0900" / "-0530" を分に直す
    pub fn parseOffset(s: []const u8) ?i16 {
        if (s.len != 5 or (s[0] != '+' and s[0] != '-')) return null;
        const hh = std.fmt.parseInt(i16, s[1..3], 10) catch return null;
        const mm = std.fmt.parseInt(i16, s[3..5], 10) catch return null;
        const abs = hh * 60 + mm;
        return if (s[0] == '-') -abs else abs;
    }

    /// 同じく "1700000000 +0900" の形で書く
    pub fn format(self: Time, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d} ", .{self.secs});
        try self.formatOffset(w);
    }

    /// git log と同じ "Wed Nov 15 07:13:20 2023 +0900"
    pub fn formatHuman(self: Time, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const local = self.secs + @as(i64, self.offset_min) * 60;
        const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(local, 0)) };
        const day = epoch.getEpochDay();
        const year_day = day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const clock = epoch.getDaySeconds();

        const weekdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
        const months = [_][]const u8{
            "Jan", "Feb", "Mar", "Apr", "May", "Jun",
            "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        };
        try w.print("{s} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} {d} ", .{
            weekdays[(day.day + 4) % 7], // 1970-01-01 は木曜日
            months[month_day.month.numeric() - 1],
            month_day.day_index + 1,
            clock.getHoursIntoDay(),
            clock.getMinutesIntoHour(),
            clock.getSecondsIntoMinute(),
            year_day.year,
        });
        try self.formatOffset(w);
    }

    fn formatOffset(self: Time, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const sign: u8 = if (self.offset_min < 0) '-' else '+';
        const abs: u16 = @abs(self.offset_min);
        try w.print("{c}{d:0>2}{d:0>2}", .{ sign, abs / 60, abs % 60 });
    }
};

/// 現在時刻を、この環境のタイムゾーンで
pub fn now(io: Io, allocator: Allocator) Time {
    const nanoseconds = Io.Timestamp.now(io, .real).nanoseconds;
    const secs: i64 = @intCast(@divFloor(nanoseconds, std.time.ns_per_s));
    return .{ .secs = secs, .offset_min = localOffsetMin(io, allocator, secs) };
}

/// /etc/localtime (TZif) を読んで、その時点のオフセットを得る。読めなければ UTC 扱い
fn localOffsetMin(io: Io, allocator: Allocator, secs: i64) i16 {
    const file = Io.Dir.openFileAbsolute(io, "/etc/localtime", .{}) catch return 0;
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader: Io.File.Reader = .init(file, io, &buf);
    var tz = std.tz.Tz.parse(allocator, &reader.interface) catch return 0;
    defer tz.deinit();
    if (tz.timetypes.len == 0) return 0;

    var offset = tz.timetypes[0].offset;
    for (tz.transitions) |t| {
        if (t.ts > secs) break;
        offset = t.timetype.offset;
    }
    return @intCast(@divTrunc(offset, 60));
}

test "parse and format" {
    const t = Time.parse("1700000000 +0900").?;
    try std.testing.expectEqual(1700000000, t.secs);
    try std.testing.expectEqual(540, t.offset_min);
    try std.testing.expectFmt("1700000000 +0900", "{f}", .{t});

    try std.testing.expectEqual(-330, Time.parse("@1 -0530").?.offset_min);
    try std.testing.expectFmt("1 -0530", "{f}", .{Time.parse("@1 -0530").?});
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try t.formatHuman(&out.writer);
    try std.testing.expectEqualStrings("Wed Nov 15 07:13:20 2023 +0900", out.written());

    try std.testing.expectEqual(null, Time.parse("yesterday"));
    try std.testing.expectEqual(null, Time.parse("1700000000 +9"));
}
