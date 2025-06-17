const module = @import("module.zig");
const std = @import("std");

fn fetch(self: module.Module, allocator: std.mem.Allocator) []const u8 {
    // Try to open; on failure, return a default placeholder
    const file = std.fs.openFileAbsolute("/proc/loadavg", .{}) catch return "n/a"[0..];
    defer file.close();

    var buf: [64]u8 = undefined;
    const n = file.readAll(&buf) catch return "n/a"[0..];
    const slice = buf[0..n];
    const first_space = std.mem.indexOf(u8, slice, " ") orelse return "n/a"[0..];
    const one_min = slice[0..first_space];

    return std.fmt.allocPrint(allocator, "{s} {s}", .{ self.icons, one_min }) catch "n/a"[0..];
}

pub const Cpu = module.Module{
    .name = "CPU",
    .icons = "^fg(789978)   ^fg()",
    .fetch = fetch,
};
