const std = @import("std");

pub const Module = struct {
    name: []const u8,
    icons: []const u8,
    fetch: *const fn (self: Module, std.mem.Allocator) []const u8,
};
