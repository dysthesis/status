const std = @import("std");
const c = @cImport(@cInclude("time.h"));
const module = @import("module.zig");

const State = struct { rx: u64, tx: u64, t_ns: i128 };
var prev: ?State = null;

fn formatBytesPerSec(bps: u64, allocator: std.mem.Allocator) ![]const u8 {
    const units = [_][]const u8{ "B/s", "KiB/s", "MiB/s", "GiB/s", "TiB/s" };

    var value = @as(f64, @floatFromInt(bps));
    var idx: usize = 0;
    while (value >= 1024.0 and idx + 1 < units.len) : (idx += 1) {
        value /= 1024.0;
    }

    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();

    const w = list.writer();
    if (value < 100.0) {
        try w.print("{d:.1} {s}", .{ value, units[idx] });
    } else {
        try w.print("{d:.0} {s}", .{ value, units[idx] });
    }
    return list.toOwnedSlice(); // caller frees
}

fn readCounters(iface: []const u8, allocator: std.mem.Allocator) !?State {
    var file = try std.fs.openFileAbsolute("/proc/net/dev", .{ .mode = .read_only });
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    var r = buf_reader.reader();

    _ = try r.readUntilDelimiterOrEofAlloc(allocator, '\n', 8 * 1024);
    _ = try r.readUntilDelimiterOrEofAlloc(allocator, '\n', 8 * 1024);

    while (true) {
        const maybe = try r.readUntilDelimiterOrEofAlloc(allocator, '\n', 8 * 1024);
        const line = maybe orelse break;
        defer allocator.free(line);

        var slice = line;
        while (slice.len > 0 and slice[0] == ' ')
            slice = slice[1..];

        if (!std.mem.startsWith(u8, slice, iface)) continue;

        var it = std.mem.tokenizeAny(u8, slice, " :");
        _ = it.next(); // iface itself
        const rx_str = it.next().?;
        var i: usize = 0;
        while (i < 7) : (i += 1) _ = it.next();
        const tx_str = it.next().?;

        return State{
            .rx = try std.fmt.parseInt(u64, rx_str, 10),
            .tx = try std.fmt.parseInt(u64, tx_str, 10),
            .t_ns = std.time.nanoTimestamp(),
        };
    }
    return null;
}

fn fetch(self: module.Module, allocator: std.mem.Allocator) []const u8 {
    const iface = "wlp4s0:"; // change or read from cfg
    const now = readCounters(iface, allocator) catch |err| {
        std.log.err("net module: {s}", .{@errorName(err)});
        return "n/a";
    } orelse return "n/a";

    if (prev == null) {
        prev = now;
        return "0 B/s 0 B/s";
    }

    const delta_rx = now.rx - prev.?.rx;
    const delta_tx = now.tx - prev.?.tx;
    const delta_t_ns = now.t_ns - prev.?.t_ns;
    if (delta_t_ns <= 0) return "n/a"; // avoid divide-by-zero or time warp
    const delta_t = @as(f64, @floatFromInt(delta_t_ns)) / 1e9;

    // **bytes per second**, no ×8!
    const down_Bps = @as(u64, @intFromFloat(@as(f64, @floatFromInt(delta_rx)) / delta_t));
    const up_Bps = @as(u64, @intFromFloat(@as(f64, @floatFromInt(delta_tx)) / delta_t));
    prev = now;

    const down_txt = formatBytesPerSec(down_Bps, allocator) catch "n/a";
    const up_txt = formatBytesPerSec(up_Bps, allocator) catch "n/a";
    return std.fmt.allocPrint(
        allocator,
        "{s}{s}^fg(FFAA88) ↓ ^fg(){s}^fg(FFAA88) ↑^fg()",
        .{ self.icons, down_txt, up_txt },
    ) catch "n/a";
}

pub const Net = module.Module{
    .name = "Network",
    .icons = "  ",
    .fetch = fetch,
};
