const std = @import("std");
const posix = std.posix;
const c = @cImport(@cInclude("time.h")); // strftime, time, localtime_r

const DELIM = "^fg(2A2A2A) |^fg()";

pub fn main() !void {
    // single allocator for all tmp strings
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // buffered stdout like in your shell loop
    var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
    const out = bw.writer();

    while (true) {
        const cpu_str = try cpu(alloc);
        const mem_str = try mem(alloc);
        const clock_str = try clock(alloc);
        defer {
            alloc.free(cpu_str);
            alloc.free(mem_str);
            alloc.free(clock_str);
        }

        const line = try std.fmt.allocPrint(
            alloc,
            "  {s}{s}{s}{s}{s}{s}      \n",
            .{ cpu_str, DELIM, mem_str, DELIM, clock_str, DELIM },
        );
        defer alloc.free(line);

        try out.print("{s}", .{line});
        try bw.flush();
        std.time.sleep(1_000_000_000);
    }
}

/// Print out the given text with the given foreground and background
pub fn colour(
    allocator: std.mem.Allocator,
    text: []const u8,
    comptime fg: ?[]const u8,
    comptime bg: ?[]const u8,
) ![]u8 {
    const use_fg = comptime fg != null;
    const use_bg = comptime bg != null;

    const fmt = comptime if (use_fg and use_bg)
        "^fg({s})^bg({s}){s}^fg()^bg()"
    else if (use_fg)
        "^fg({s}){s}^fg()"
    else if (use_bg)
        "^bg({s}){s}^bg()"
    else
        "{s}";

    const args = if (use_fg and use_bg)
        .{ fg.?, bg.?, text }
    else if (use_fg)
        .{ fg.?, text }
    else if (use_bg)
        .{ bg.?, text }
    else
        .{text};

    return std.fmt.allocPrint(allocator, fmt, args);
}

fn cpu(alloc: std.mem.Allocator) ![]u8 {
    var file = try std.fs.openFileAbsolute("/proc/loadavg", .{});
    defer file.close();

    var buf: [64]u8 = undefined;
    const n = try file.readAll(&buf); // OK now
    const slice = buf[0..n];

    // first number before the first space = 1-min load
    const first_space = std.mem.indexOf(u8, slice, " ").?;
    const one_min = slice[0..first_space];

    return colour(alloc, one_min, "708090", null);
}

fn mem(alloc: std.mem.Allocator) ![]u8 {
    var file = try std.fs.openFileAbsolute("/proc/meminfo", .{});
    defer file.close();

    var buf: [2048]u8 = undefined;
    const len = try file.readAll(&buf);

    var total_kib: u64 = 0;
    var avail_kib: u64 = 0;

    var it = std.mem.splitScalar(u8, buf[0..len], '\n');
    while (it.next()) |ln| {
        if (std.mem.startsWith(u8, ln, "MemTotal:") or std.mem.startsWith(u8, ln, "MemAvailable:")) {
            // split the *whole* line on spaces, first numeric token is the value
            var tok = std.mem.tokenizeScalar(u8, ln, ' ');
            _ = tok.next(); // first token is the label
            while (tok.next()) |t| { // skip empty runs
                if (t.len != 0) {
                    const val = try std.fmt.parseInt(u64, t, 10);
                    if (std.mem.startsWith(u8, ln, "MemTotal:"))
                        total_kib = val
                    else
                        avail_kib = val;
                    break;
                }
            }
        }
    }

    const used_kib = total_kib - avail_kib;
    const used_gib = @as(f64, @floatFromInt(used_kib)) / 1024.0 / 1024.0; // GiB

    const pretty = try std.fmt.allocPrint(alloc, "{d:.1} GiB", .{used_gib});
    return colour(alloc, pretty, "789978", null);
}

fn clock(alloc: std.mem.Allocator) ![]u8 {
    var now_raw: c.time_t = c.time(null);
    var tm: c.struct_tm = undefined;
    _ = c.localtime_r(&now_raw, &tm);

    var buf: [20]u8 = undefined; // exactly 16 bytes + NUL
    const written = c.strftime(&buf, buf.len, "%Y-%m-%d %H:%M", &tm);
    if (written == 0) return error.ClockFormatFailed;
    const slice = buf[0..written];

    return colour(alloc, slice, "7788AA", null);
}
