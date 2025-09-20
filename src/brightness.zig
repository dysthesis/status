const std = @import("std");
const module = @import("module.zig");

const backlight_dir = "/sys/class/backlight";

const DetectionState = enum {
    unknown,
    supported,
    unsupported,
};

var detection_state: DetectionState = .unknown;
var device_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
var device_dir_len: usize = 0;

fn readValue(path: []const u8) ?u64 {
    const file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch return null;
    defer file.close();

    var buf: [64]u8 = undefined;
    const amt = file.read(&buf) catch return null;
    if (amt == 0) return null;

    const trimmed = std.mem.trim(u8, buf[0..amt], " \t\r\n");
    if (trimmed.len == 0) return null;

    return std.fmt.parseInt(u64, trimmed, 10) catch null;
}

fn readBrightness(dir_path: []const u8) ?u64 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;

    const actual_path = std.fmt.bufPrint(&path_buf, "{s}/actual_brightness", .{dir_path}) catch return null;
    if (readValue(actual_path)) |val| return val;

    const brightness_path = std.fmt.bufPrint(&path_buf, "{s}/brightness", .{dir_path}) catch return null;
    return readValue(brightness_path);
}

fn readMax(dir_path: []const u8) ?u64 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/max_brightness", .{dir_path}) catch return null;
    return readValue(path);
}

fn detectDevice() bool {
    var dir = std.fs.openDirAbsolute(backlight_dir, .{ .iterate = true }) catch {
        detection_state = .unsupported;
        return false;
    };
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch return false) |entry| {
        if (entry.name.len == 0) continue;
        if (entry.name[0] == '.') continue;

        var candidate_buf: [std.fs.max_path_bytes]u8 = undefined;
        const candidate = std.fmt.bufPrint(&candidate_buf, "{s}/{s}", .{ backlight_dir, entry.name }) catch continue;

        const max_val = readMax(candidate) orelse continue;
        if (max_val == 0) continue;

        if (readBrightness(candidate) == null) continue;

        std.mem.copyForwards(u8, device_dir_buf[0..candidate.len], candidate);
        device_dir_len = candidate.len;
        detection_state = .supported;
        return true;
    }

    device_dir_len = 0;
    detection_state = .unsupported;
    return false;
}

fn ensureDevice() bool {
    return switch (detection_state) {
        .supported => true,
        .unsupported => false,
        .unknown => detectDevice(),
    };
}

pub fn isSupported() bool {
    return ensureDevice();
}

fn fetch(self: module.Module, allocator: std.mem.Allocator) []const u8 {
    if (!ensureDevice()) return "n/a";

    const dir_path = device_dir_buf[0..device_dir_len];

    const current = readBrightness(dir_path) orelse {
        detection_state = .unknown;
        return "n/a";
    };

    const max_val = readMax(dir_path) orelse {
        detection_state = .unknown;
        return "n/a";
    };

    if (max_val == 0) {
        detection_state = .unknown;
        return "n/a";
    }

    var percent_u128 = (@as(u128, current) * 100) + (@as(u128, max_val) / 2);
    percent_u128 = percent_u128 / @as(u128, max_val);
    if (percent_u128 > 100) percent_u128 = 100;
    const percent = @as(usize, @intCast(percent_u128));

    return std.fmt.allocPrint(
        allocator,
        "{s} {d}%^fg(444444) ({d}/{d})^fg()",
        .{ self.icons, percent, current, max_val },
    ) catch "n/a";
}

pub const Brightness = module.Module{
    .name = "Brightness",
    .icons = "^fg(FFCC66)  󰃠 ^fg()",
    .fetch = fetch,
};
