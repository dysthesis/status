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
        const cpu_str = cpu(alloc) catch try std.fmt.allocPrint(alloc, "n/a", .{});
        const cpu_icon = get_icon(icons.Cpu);
        const mem_str = mem(alloc) catch try std.fmt.allocPrint(alloc, "n/a", .{});
        const mem_icon = get_icon(icons.Mem);
        const clock_str = clock() catch try std.fmt.allocPrint(alloc, "n/a", .{});
        const clock_icon = get_icon(icons.Clock);
        defer {
            alloc.free(cpu_str);
            alloc.free(mem_str);
        }

        const line = try std.fmt.allocPrint(
            alloc,
            "  {s} {s} {s} {s} {s} {s} {s} {s} {s}      \n",
            .{ cpu_icon, cpu_str, DELIM, mem_icon, mem_str, DELIM, clock_icon, clock_str, DELIM },
        );
        defer alloc.free(line);

        try out.print("{s}", .{line});
        try bw.flush();
        std.time.sleep(1_000_000_000);
    }
}

const icons = enum {
    Mem,
    Cpu,
    Clock,
};

pub fn get_icon(comptime icon: icons) []const u8 {
    return switch (icon) {
        .Mem => colour("   ", "708090", null),
        .Cpu => colour("   ", "789978", null),
        .Clock => colour("  󱑆 ", "7788AA", null),
    };
}

/// Print out the given text with the given foreground and background
pub fn colour(
    comptime text: []const u8,
    comptime fg: ?[]const u8,
    comptime bg: ?[]const u8,
) []const u8 {
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

    return std.fmt.comptimePrint(fmt, args);
}

fn cpu(allocator: std.mem.Allocator) ![]u8 {
    // Try to open; on failure, return a default placeholder
    const file = std.fs.openFileAbsolute("/proc/loadavg", .{}) catch {
        // ignore the error and return a placeholder
        return try std.fmt.allocPrint(allocator, "n/a", .{});
    };
    defer file.close();

    var buf: [64]u8 = undefined;
    const n = try file.readAll(&buf);
    const slice = buf[0..n];
    const first_space = std.mem.indexOf(u8, slice, " ").?;
    const one_min = slice[0..first_space];

    return try std.fmt.allocPrint(allocator, "{s}", .{one_min});
}

fn mem(allocator: std.mem.Allocator) ![]u8 {
    const file = std.fs.openFileAbsolute("/proc/meminfo", .{ .mode = .read_only }) catch return try std.fmt.allocPrint(allocator, "n/a", .{});
    defer file.close();

    var buf: [2048]u8 = undefined;
    const len = file.readAll(&buf) catch return try std.fmt.allocPrint(allocator, "n/a", .{});

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

    const res = std.fmt.allocPrint(allocator, "{d:.1} GiB", .{used_gib}) catch return try std.fmt.allocPrint(allocator, "n/a", .{});
    return res;
}

fn clock() ![]u8 {
    var now_raw: c.time_t = c.time(null);
    var tm: c.struct_tm = undefined;
    _ = c.localtime_r(&now_raw, &tm);

    var buf: [20]u8 = undefined; // exactly 16 bytes + NUL
    const written = c.strftime(&buf, buf.len, "%Y-%m-%d %H:%M", &tm);
    if (written == 0) return error.ClockFormatFailed;
    return buf[0..written];
}
