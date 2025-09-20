const std = @import("std");
const DELIM = "^fg(2A2A2A) |^fg()";

const brightness = @import("brightness.zig");
const cpu = @import("cpu.zig");
const clock = @import("clock.zig");
const mem = @import("mem.zig");
const module = @import("module.zig");
const net = @import("network.zig");
const volume = @import("volume.zig");
const task = @import("task.zig");

const tray_size = 0;

const max_modules = 7;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
    const out = bw.writer();

    var modules_buf: [max_modules]module.Module = undefined;
    var module_count: usize = 0;

    modules_buf[module_count] = task.Taskwarrior;
    module_count += 1;
    if (brightness.isSupported()) {
        modules_buf[module_count] = brightness.Brightness;
        module_count += 1;
    }
    modules_buf[module_count] = volume.Volume;
    module_count += 1;
    modules_buf[module_count] = net.Net;
    module_count += 1;

    modules_buf[module_count] = mem.Mem;
    module_count += 1;
    modules_buf[module_count] = cpu.Cpu;
    module_count += 1;
    modules_buf[module_count] = clock.Clock;
    module_count += 1;

    const modules = modules_buf[0..module_count];

    while (true) {
        _ = arena.reset(.free_all);

        var parts: [max_modules * 2][]const u8 = undefined;

        for (modules, 0..) |m, i| {
            parts[i * 2] = m.fetch(m, alloc);
            parts[(i * 2) + 1] = DELIM;
        }

        const status = try std.mem.concat(alloc, u8, parts[0 .. module_count * 2]);
        const tray_padding = " " ** tray_size;

        try out.print("{s}{s}\n", .{ status, tray_padding });
        try bw.flush();
        std.time.sleep(1_000_000_000);
    }
}
