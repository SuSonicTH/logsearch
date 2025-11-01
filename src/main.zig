const std = @import("std");
const builtin = @import("builtin");
const LogSearch = @import("LogSearch.zig");

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

    try options.addLevel("WARN");
    try options.addLevel("ERROR");
    try options.addFile("BlackMed.log");
    try options.addExpression("Unable to find active contract for MSISDN");

    var logSearch = LogSearch.init(&options);
    defer logSearch.deinit();

    try logSearch.run();
}
