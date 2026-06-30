const std = @import("std");
const module = @import("module.zig");
const c = @cImport(@cInclude("time.h")); // time, timegm, struct tm

// global_single_threaded uses a .failing allocator, so process.run's internal
// pipe machinery OOMs; it also defaults to an empty environ, so the spawned
// `/usr/bin/env task` has no PATH and exits 127 (empty stdout -> "No tasks").
// Lazily build a real Threaded IO seeded with the process environment and reuse
// it across fetches (page_allocator is threadsafe; only used for async).
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

/// Helper that runs `task export` (or anything passed in `argv`) and returns its stdout as a fresh
/// heap slice.
fn run_command(allocator: std.mem.Allocator) ![]u8 {
    const argv = &[_][]const u8{
        "/usr/bin/env",
        "task",
        "rc.verbose:nothing", // silence headers
        "+READY",
        "status:pending",
        "export",
    };

    const res = try std.process.run(allocator, currentIo(), .{
        .argv = argv,
        .stdout_limit = .limited(16 * 1024), // enough for ~500 tasks
        .stderr_limit = .limited(16 * 1024),
    });
    defer allocator.free(res.stderr); // we don’t use stderr
    return res.stdout; // caller frees
}

/// Parse a Taskwarrior JSON array (produced by `task ... export`) and pull out description and due
/// date of the first task. Returns freshly allocated slices owned by `a`.
fn first_task(json: []const u8, a: std.mem.Allocator, now_epoch: i64) ?struct {
    desc: []const u8,
    due_raw: ?[]const u8,
    due_within_week: usize,
} {
    const trimmed = std.mem.trim(u8, json, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "[]"))
        return null; // nothing ready

    // scratch allocator (4 KiB stack, spills to caller’s arena)
    var sfa = std.heap.stackFallback(4096, a);
    const gpa = sfa.get();

    var parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .array or root.array.items.len == 0)
        return null;

    var best_idx: usize = 0;
    var best_urg: f64 = -1;
    var due_in_week_count: usize = 0;
    const week_window_end = now_epoch + (7 * 24 * 60 * 60);

    for (root.array.items, 0..) |item, idx| {
        if (item != .object) continue; // safety
        const obj = item.object;

        if (obj.get("due")) |due_v| {
            if (due_v == .string and due_v.string.len >= 8) {
                if (parseDueEpoch(due_v.string)) |due_epoch| {
                    if (due_epoch >= now_epoch and due_epoch <= week_window_end)
                        due_in_week_count += 1;
                }
            }
        }

        const urg = if (obj.get("urgency")) |u|
            switch (u) {
                .float => u.float,
                .integer => @as(f64, @floatFromInt(u.integer)),
                else => 0,
            }
        else
            0;
        if (urg > best_urg) {
            best_urg = urg;
            best_idx = idx;
        }
    }

    const best = root.array.items[best_idx];
    if (best != .object) return null; // defensive

    const obj = best.object;
    const desc_v = obj.get("description") orelse return null;
    if (desc_v != .string) return null;
    const desc_src = desc_v.string;

    // optional due date (keep raw Taskwarrior timestamp, e.g. YYYYMMDD or YYYYMMDDTHHMMSSZ)
    const due_opt_v = obj.get("due");
    var due_opt: ?[]const u8 = null;
    if (due_opt_v) |dv| if (dv == .string and dv.string.len >= 8) {
        const due_buf = a.alloc(u8, dv.string.len) catch return null;
        std.mem.copyForwards(u8, due_buf, dv.string);
        due_opt = due_buf;
    };

    // Copy description to caller-owned memory
    const desc_buf = a.alloc(u8, desc_src.len) catch return null;
    std.mem.copyForwards(u8, desc_buf, desc_src);

    return .{ .desc = desc_buf, .due_raw = due_opt, .due_within_week = due_in_week_count };
}

fn parseUint(comptime T: type, s: []const u8) ?T {
    return std.fmt.parseInt(T, s, 10) catch null;
}

// Parse Taskwarrior due string (YYYYMMDD or YYYYMMDDTHHMMSS[Z]) to epoch seconds (UTC)
fn parseDueEpoch(d: []const u8) ?i64 {
    if (d.len < 8) return null;
    const year = parseUint(i32, d[0..4]) orelse return null;
    const mon = parseUint(i32, d[4..6]) orelse return null;
    const day = parseUint(i32, d[6..8]) orelse return null;

    var hour: i32 = 0;
    var min: i32 = 0;
    var sec: i32 = 0;
    if (d.len >= 15 and d[8] == 'T') {
        hour = parseUint(i32, d[9..11]) orelse 0;
        min = parseUint(i32, d[11..13]) orelse 0;
        sec = parseUint(i32, d[13..15]) orelse 0;
    }

    var tm: c.struct_tm = std.mem.zeroes(c.struct_tm);
    tm.tm_year = year - 1900;
    tm.tm_mon = mon - 1;
    tm.tm_mday = day;
    tm.tm_hour = hour;
    tm.tm_min = min;
    tm.tm_sec = sec;
    tm.tm_isdst = 0;

    // Interpret as UTC if possible
    const t: c.time_t = c.timegm(&tm);
    return @as(i64, @intCast(t));
}

fn formatRelative(buf: []u8, now_epoch: i64, due_epoch: i64) []const u8 {
    var diff: i64 = due_epoch - now_epoch;
    const future = diff >= 0;
    if (!future) diff = -diff;

    const sec_per_min: i64 = 60;
    const sec_per_hour: i64 = 60 * 60;
    const sec_per_day: i64 = 24 * 60 * 60;

    var n: i64 = 0;
    var unit: u8 = 's';
    if (diff >= sec_per_day) {
        n = @divTrunc(diff, sec_per_day);
        unit = 'd';
    } else if (diff >= sec_per_hour) {
        n = @divTrunc(diff, sec_per_hour);
        unit = 'h';
    } else if (diff >= sec_per_min) {
        n = @divTrunc(diff, sec_per_min);
        unit = 'm';
    } else {
        n = diff;
        unit = 's';
    }

    if (future) {
        const written = std.fmt.bufPrint(buf, "in {d}{c}", .{ n, unit }) catch return "in ?";
        return buf[0..written.len];
    } else {
        const written = std.fmt.bufPrint(buf, "{d}{c} ago", .{ n, unit }) catch return "? ago";
        return buf[0..written.len];
    }
}

/// The `fetch` function exposed to the status-bar core.
fn fetch(self: module.Module, allocator: std.mem.Allocator) []const u8 {
    const raw = run_command(allocator) catch {
        return "n/a"[0..]; // spawn/read failure
    };
    defer allocator.free(raw);

    const now_epoch: i64 = @as(i64, @intCast(c.time(null)));
    const task_opt = first_task(raw, allocator, now_epoch);
    if (task_opt == null)
        return std.fmt.allocPrint(allocator, "{s} No tasks", .{self.icons}) catch "n/a"[0..];

    const task = task_opt.?;

    // Bound only the visible description so a runaway task can't blow out the
    // bar; markup (^fg codes) and the due suffix are always emitted in full so
    // colour codes never get sliced and the due date never drops off.
    const DESC_MAX = 80;
    const desc = truncDesc(task.desc, DESC_MAX);
    const ellipsis: []const u8 = if (task.desc.len > desc.len) "…" else "";

    // muted count of tasks due within the next 7 days, only when non-zero
    var count_buf: [32]u8 = undefined;
    const count_seg: []const u8 = if (task.due_within_week > 0)
        std.fmt.bufPrint(&count_buf, "^fg(444444)({d})^fg()  ", .{task.due_within_week}) catch ""
    else
        "";

    // optional due suffix: relative time, else YYYY-MM-DD fallback
    var due_buf: [64]u8 = undefined;
    const due_seg: []const u8 = blk: {
        const d = task.due_raw orelse break :blk "";
        if (parseDueEpoch(d)) |due_epoch| {
            var rbuf: [24]u8 = undefined;
            const rel = formatRelative(&rbuf, now_epoch, due_epoch);
            break :blk std.fmt.bufPrint(&due_buf, " ^fg(FFAA88)due {s}^fg()", .{rel}) catch "";
        } else if (d.len >= 8) {
            break :blk std.fmt.bufPrint(&due_buf, " ^fg(FFAA88)due {s}-{s}-{s}^fg()", .{ d[0..4], d[4..6], d[6..8] }) catch "";
        }
        break :blk "";
    };

    return std.fmt.allocPrint(allocator, "{s} {s}{s}{s}{s}", .{
        self.icons, count_seg, desc, ellipsis, due_seg,
    }) catch "n/a";
}

/// Truncate to at most `max` bytes without splitting a UTF-8 codepoint.
fn truncDesc(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1; // back off continuation bytes
    return s[0..end];
}

test truncDesc {
    try std.testing.expectEqualStrings("abc", truncDesc("abc", 80)); // shorter than max -> untouched
    try std.testing.expectEqualStrings("ab", truncDesc("abcd", 2)); // plain ascii cut
    // "é" is 2 bytes (C3 A9): cutting at byte 3 must drop it whole, not split it
    try std.testing.expectEqualStrings("a", truncDesc("aéb", 2));
    try std.testing.expectEqualStrings("aé", truncDesc("aéb", 3));
}

/// Public value the status-bar will import.
pub const Taskwarrior = module.Module{
    .name = "Taskwarrior",
    .icons = "^fg(85AF5F)   ^fg()",
    .fetch = fetch,
};
