const std = @import("std");
const builtin = @import("builtin");
const LogSearch = @import("LogSearch.zig");
const Arguments = @import("Arguments.zig");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    var options = LogSearch.Options.init(allocator);
    defer options.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const arguments = try castArgs(args, allocator);
    defer allocator.free(arguments);

    try Arguments.parse(&options, arguments);

    var logSearch = LogSearch.init(&options);
    defer logSearch.deinit();

    try logSearch.run();
}

fn castArgs(args: [][:0]u8, allocator: std.mem.Allocator) ![][]const u8 {
    var ret = try allocator.alloc([]const u8, args.len);
    for (args, 0..) |arg, i| {
        ret[i] = arg[0..];
    }
    return ret;
}
