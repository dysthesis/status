const std = @import("std");
const c = @cImport(@cInclude("time.h"));
const module = @import("module.zig");

const State = struct { rx: u64, tx: u64, t_ns: i128 };
var prev: ?State = null;
const max_iface_len = 32;
var last_iface_buf: [max_iface_len]u8 = undefined;
var last_iface_len: usize = 0;
var last_iface_valid = false;

fn detectWirelessInterface(allocator: std.mem.Allocator) !?[]u8 {
    var file = std.fs.openFileAbsolute("/proc/net/wireless", .{ .mode = .read_only }) catch |err| {
        return switch (err) {
            error.FileNotFound, error.AccessDenied => null,
            else => err,
        };
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 8 * 1024);
    defer allocator.free(content);

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var line_index: usize = 0;
    while (line_iter.next()) |line| {
        if (line_index < 2) {
            line_index += 1;
            continue;
        }

        const trimmed = std.mem.trimLeft(u8, line, " ");
        if (trimmed.len == 0) continue;

        const colon_index = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const iface = trimmed[0 .. colon_index + 1];
        return try allocator.dupe(u8, iface);
    }

    return null;
}

fn formatBytesPerSec(bps: u64, allocator: std.mem.Allocator) ![]const u8 {
    const units = [_][]const u8{ "B/s", "KiB/s", "MiB/s", "GiB/s", "TiB/s" };

    var value = @as(f64, @floatFromInt(bps));
    var idx: usize = 0;
    while (value >= 1024.0 and idx + 1 < units.len) : (idx += 1) {
        value /= 1024.0;
    }

    var list = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    errdefer list.deinit(allocator);

    const w = list.writer(allocator);
    if (value < 100.0) {
        try w.print("{d:.1} {s}", .{ value, units[idx] });
    } else {
        try w.print("{d:.0} {s}", .{ value, units[idx] });
    }
    return list.toOwnedSlice(allocator); // caller frees
}

fn readCounters(iface: []const u8, allocator: std.mem.Allocator) !?State {
    var file = try std.fs.openFileAbsolute("/proc/net/dev", .{ .mode = .read_only });
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 8 * 1024);
    defer allocator.free(content);

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    _ = line_iter.next(); // skip first line
    _ = line_iter.next(); // skip second line

    while (line_iter.next()) |line| {

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
    const maybe_iface = detectWirelessInterface(allocator) catch |err| {
        std.log.err("net module: {s}", .{@errorName(err)});
        return "n/a";
    };

    const iface = maybe_iface orelse return "n/a";
    defer allocator.free(iface);

    if (iface.len > max_iface_len) {
        std.log.err("net module: iface name too long", .{});
        return "n/a";
    }

    const iface_changed = if (last_iface_valid)
        !std.mem.eql(u8, last_iface_buf[0..last_iface_len], iface)
    else
        true;

    if (iface_changed) {
        std.mem.copyForwards(u8, last_iface_buf[0..iface.len], iface);
        last_iface_len = iface.len;
        last_iface_valid = true;
        prev = null;
    }

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

    const display_iface = if (iface.len > 0 and iface[iface.len - 1] == ':')
        iface[0 .. iface.len - 1]
    else
        iface;

    return std.fmt.allocPrint(
        allocator,
        "{s} {s}^fg(FFAA88) ↓ ^fg(){s}^fg(FFAA88) ↑^fg() ^fg(444444)({s})^fg()",
        .{ self.icons, down_txt, up_txt, display_iface },
    ) catch "n/a";
}

pub const Net = module.Module{
    .name = "Network",
    .icons = "  ",
    .fetch = fetch,
};
