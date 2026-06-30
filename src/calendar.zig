const std = @import("std");
const module = @import("module.zig");
const c = @cImport(@cInclude("time.h")); // time, mktime, struct tm

// Same reasoning as task.zig: the status core runs single-threaded with a
// .failing allocator and an empty environ, so process.run would OOM and the
// spawned `/usr/bin/env khal` would have no PATH. Build a real Threaded IO
// seeded with the process environment once and reuse it.
var threaded_io: ?std.Io.Threaded = null;

fn currentIo() std.Io {
    if (threaded_io == null) {
        const c_environ = std.c.environ;
        var n: usize = 0;
        while (c_environ[n] != null) : (n += 1) {}
        threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{
            .environ = .{ .block = .{ .slice = c_environ[0..n :null] } },
        });
    }
    return threaded_io.?.io();
}

// simplification: 60-day look-ahead window. Events further out than this read as
// "No events"; widen the "60d" arg if that ever bites.
fn run_command(allocator: std.mem.Allocator) ![]u8 {
    const argv = &[_][]const u8{
        "/usr/bin/env",  "khal",
        "list",          "now",
        "60d",           "--notstarted", // only events that have not started yet
        "-o", // print each event once
        "--day-format",  "", // suppress per-day header lines
        "--format",      "{start}\t{title}",
    };

    const res = try std.process.run(allocator, currentIo(), .{
        .argv = argv,
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    });
    defer allocator.free(res.stderr);
    return res.stdout; // caller frees
}

/// Pull the first real event line out of khal's output. khal still emits blank
/// lines between (now header-less) days, so skip whitespace-only lines. Returns
/// the `{start}` and `{title}` halves (split on the first tab), both borrowing
/// from `out`.
fn firstEvent(out: []const u8) ?struct { start: []const u8, title: []const u8 } {
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, trimmed, '\t') orelse continue;
        return .{ .start = trimmed[0..tab], .title = trimmed[tab + 1 ..] };
    }
    return null;
}

fn parseUint(comptime T: type, s: []const u8) ?T {
    return std.fmt.parseInt(T, s, 10) catch null;
}

/// Parse khal's local-time `{start}`: "YYYY-MM-DD" or "YYYY-MM-DD HH:MM".
/// Interpreted in the local zone (khal prints local times), so mktime, not
/// timegm. All-day events have no time and fall back to local midnight.
fn parseStartEpoch(s: []const u8) ?i64 {
    if (s.len < 10) return null;
    const year = parseUint(i32, s[0..4]) orelse return null;
    const mon = parseUint(i32, s[5..7]) orelse return null;
    const day = parseUint(i32, s[8..10]) orelse return null;

    var hour: i32 = 0;
    var min: i32 = 0;
    if (s.len >= 16 and s[10] == ' ') {
        hour = parseUint(i32, s[11..13]) orelse 0;
        min = parseUint(i32, s[14..16]) orelse 0;
    }

    var tm: c.struct_tm = std.mem.zeroes(c.struct_tm);
    tm.tm_year = year - 1900;
    tm.tm_mon = mon - 1;
    tm.tm_mday = day;
    tm.tm_hour = hour;
    tm.tm_min = min;
    tm.tm_isdst = -1; // let libc resolve DST for the local zone

    const t: c.time_t = c.mktime(&tm);
    return @as(i64, @intCast(t));
}

/// "in 13d" / "in 4h" / "in 25m" / "now". Future-only: --notstarted guarantees
/// start >= now, but clamp negatives to "now" against clock skew.
fn formatIn(buf: []u8, now_epoch: i64, start_epoch: i64) []const u8 {
    const diff = start_epoch - now_epoch;
    if (diff <= 0) return "now";

    const sec_per_min: i64 = 60;
    const sec_per_hour: i64 = 60 * 60;
    const sec_per_day: i64 = 24 * 60 * 60;

    var n: i64 = undefined;
    var unit: u8 = undefined;
    if (diff >= sec_per_day) {
        n = @divTrunc(diff, sec_per_day);
        unit = 'd';
    } else if (diff >= sec_per_hour) {
        n = @divTrunc(diff, sec_per_hour);
        unit = 'h';
    } else {
        n = @divTrunc(diff, sec_per_min);
        unit = 'm';
    }
    const written = std.fmt.bufPrint(buf, "in {d}{c}", .{ n, unit }) catch return "in ?";
    return buf[0..written.len];
}

/// Truncate to at most `max` bytes without splitting a UTF-8 codepoint.
fn truncTitle(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

fn fetch(self: module.Module, allocator: std.mem.Allocator) []const u8 {
    const raw = run_command(allocator) catch return "n/a"[0..];
    defer allocator.free(raw);

    const ev = firstEvent(raw) orelse
        return std.fmt.allocPrint(allocator, "{s} No events", .{self.icons}) catch "n/a"[0..];

    const TITLE_MAX = 80;
    const title = truncTitle(ev.title, TITLE_MAX);
    const ellipsis: []const u8 = if (ev.title.len > title.len) "…" else "";

    var when_buf: [64]u8 = undefined;
    const when_seg: []const u8 = blk: {
        const start = parseStartEpoch(ev.start) orelse break :blk "";
        const now_epoch: i64 = @as(i64, @intCast(c.time(null)));
        var rbuf: [24]u8 = undefined;
        const rel = formatIn(&rbuf, now_epoch, start);
        break :blk std.fmt.bufPrint(&when_buf, " ^fg(FFAA88){s}^fg()", .{rel}) catch "";
    };

    return std.fmt.allocPrint(allocator, "{s} {s}{s}{s}", .{
        self.icons, title, ellipsis, when_seg,
    }) catch "n/a"[0..];
}

pub const Calendar = module.Module{
    .name = "Calendar",
    .icons = "^fg(B48EAD)  󰃭 ^fg()",
    .fetch = fetch,
};

test firstEvent {
    const out = "\n2026-06-30 22:00\tSleep\n\n2026-07-01 08:00\tWake up\n";
    const ev = firstEvent(out).?;
    try std.testing.expectEqualStrings("2026-06-30 22:00", ev.start);
    try std.testing.expectEqualStrings("Sleep", ev.title);
    try std.testing.expect(firstEvent("\n  \n\t\n") == null);
}

test formatIn {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("in 2d", formatIn(&buf, 0, 2 * 24 * 3600 + 5));
    try std.testing.expectEqualStrings("in 4h", formatIn(&buf, 0, 4 * 3600 + 5));
    try std.testing.expectEqualStrings("in 25m", formatIn(&buf, 0, 25 * 60));
    try std.testing.expectEqualStrings("now", formatIn(&buf, 100, 100));
    try std.testing.expectEqualStrings("now", formatIn(&buf, 100, 50));
}

test parseStartEpoch {
    // date-only (all-day) and date+time both parse; round-trip the field split.
    try std.testing.expect(parseStartEpoch("2026-07-13") != null);
    try std.testing.expect(parseStartEpoch("2026-06-30 22:00") != null);
    try std.testing.expect(parseStartEpoch("bad") == null);
    // 22:00 is 22h after local midnight of the same day, regardless of zone.
    const day = parseStartEpoch("2026-06-30").?;
    const evening = parseStartEpoch("2026-06-30 22:00").?;
    try std.testing.expectEqual(@as(i64, 22 * 3600), evening - day);
}
