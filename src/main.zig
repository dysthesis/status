const std = @import("std");
const DELIM = "^fg(2A2A2A) |^fg()";

const mem = @import("mem.zig");
const cpu = @import("cpu.zig");
const clock = @import("clock.zig");
const module = @import("module.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
    const out = bw.writer();

    const modules = [_]module.Module{
        mem.Mem,
        cpu.Cpu,
        clock.Clock,
    };

    while (true) {
        _ = arena.reset(.free_all);
        var parts: [modules.len][]const u8 = undefined;

        for (modules, 0..) |m, i| {
            parts[i] = m.fetch(m, alloc);
        }

        const status = try std.mem.concat(alloc, u8, parts[0..]);
        try out.print("{s}", status);
        try bw.flush();
        std.time.sleep(1_000_000_000);
    }
}
