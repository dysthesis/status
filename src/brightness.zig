const std = @import("std");
const module = @import("module.zig");

const Reading = struct {
    current: u64,
    max: u64,
};

fn parseStrictDecimal(token: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, token, " \t");
    if (trimmed.len == 0) return null;
    for (trimmed) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    return std.fmt.parseInt(u64, trimmed, 10) catch return null;
}

fn maxBrightnessGreaterThanZero(base: []const u8) bool {
    var dir = std.fs.openDirAbsolute(base, .{ .iterate = true }) catch return false;
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch return false) |entry| {
        if (entry.name.len == 0) continue;
        if (entry.name[0] == '.') continue;

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}/max_brightness", .{ base, entry.name }) catch continue;

        const file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch continue;
        defer file.close();

        var buf: [32]u8 = undefined;
        const read = file.read(&buf) catch continue;
        if (read == 0) continue;
        const trimmed = std.mem.trim(u8, buf[0..read], " \t\r\n");
        if (trimmed.len == 0) continue;
        const value = std.fmt.parseInt(u64, trimmed, 10) catch continue;
        if (value > 0) return true;
    }
    return false;
}

pub fn isSupported() bool {
    return maxBrightnessGreaterThanZero("/sys/class/backlight");
}

fn runBrightnessctl(allocator: std.mem.Allocator) ![]u8 {
    const argv = [_][]const u8{
        "/usr/bin/env",
        "brightnessctl",
        "-m",
    };

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv[0..],
        .max_output_bytes = 4096,
    });
    defer allocator.free(result.stderr);
    return result.stdout;
}

fn parseMachineReadable(raw: []const u8) ?Reading {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;

    const newline_index = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    const line = trimmed[0..newline_index];

    var tokens: [5][]const u8 = undefined;
    var token_count: usize = 0;
    var it = std.mem.splitScalar(u8, line, ',');
    while (token_count < tokens.len) {
        const tok = it.next() orelse break;
        tokens[token_count] = std.mem.trim(u8, tok, " \t");
        token_count += 1;
    }

    if (token_count < 4) return null; // need at least device,type,current,max/percent

    const current = parseStrictDecimal(tokens[2]) orelse return null;

    const max_index: usize = if (token_count >= 5)
        4
    else
        3;
    if (max_index >= token_count) return null;

    const max_val = parseStrictDecimal(tokens[max_index]) orelse return null;
    if (max_val == 0) return null;

    return Reading{ .current = current, .max = max_val };
}

fn fetch(self: module.Module, allocator: std.mem.Allocator) []const u8 {
    const raw = runBrightnessctl(allocator) catch {
        return "n/a"[0..];
    };
    defer allocator.free(raw);

    const reading = parseMachineReadable(raw) orelse return "n/a"[0..];

    const max_u128 = @as(u128, reading.max);
    const scaled = @as(u128, reading.current) * 100;
    const percent_rounded = (scaled + (max_u128 / 2)) / max_u128;
    const percent_limited = if (percent_rounded > 100) 100 else percent_rounded;
    const percent = @as(usize, @intCast(percent_limited));

    return std.fmt.allocPrint(
        allocator,
        "{s} {d}%^fg(444444) ({d}/{d})^fg()",
        .{ self.icons, percent, reading.current, reading.max },
    ) catch "n/a"[0..];
}

pub const Brightness = module.Module{
    .name = "Brightness",
    .icons = "^fg(FFCC66)  󰃠 ^fg()",
    .fetch = fetch,
};
