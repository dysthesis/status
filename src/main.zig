const std = @import("std");
const DELIM = "^fg(2A2A2A) |^fg()";

const mem = @import("mem.zig");
const cpu = @import("cpu.zig");
const clock = @import("clock.zig");
const net = @import("network.zig");
const module = @import("module.zig");

const tray_size = 10;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
    const out = bw.writer();

    const modules = [_]module.Module{
        net.Net,
        mem.Mem,
        cpu.Cpu,
        clock.Clock,
    };

    while (true) {
        _ = arena.reset(.free_all);

        var parts: [(modules.len * 2)][]const u8 = undefined;

        for (modules, 0..) |m, i| {
            parts[i * 2] = m.fetch(m, alloc);
            parts[(i * 2) + 1] = DELIM;
        }

        const status = try std.mem.concat(alloc, u8, parts[0..]);
        const tray_padding = " " ** tray_size;

        try out.print("{s}{s}", .{ status, tray_padding });
        try bw.flush();
        std.time.sleep(1_000_000_000);
    }
}
