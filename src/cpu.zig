const module = @import("module.zig");
const std = @import("std");

fn currentIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn fetch(self: module.Module, allocator: std.mem.Allocator) []const u8 {
    // Try to open; on failure, return a default placeholder
    const io = currentIo();
    const file = std.Io.Dir.openFileAbsolute(io, "/proc/loadavg", .{}) catch return "n/a"[0..];
    defer file.close(io);

    var buf: [64]u8 = undefined;
    var reader_buf: [64]u8 = undefined;
    var reader = file.readerStreaming(io, &reader_buf);
    const n = reader.interface.readSliceShort(&buf) catch return "n/a"[0..];
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
