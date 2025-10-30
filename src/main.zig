const std = @import("std");
const builtin = @import("builtin");
const LogReader = @import("LogReader.zig");

pub fn main() !void {
    //    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    //    const allocator, const is_debug = gpa: {
    //        break :gpa switch (builtin.mode) {
    //            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
    //            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
    //        };
    //    };
    //    defer if (is_debug) {
    //        _ = debug_allocator.deinit();
    //    };

    var logIter = try LogReader.init("logs/BlackMed.log");
    defer logIter.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    while (logIter.next()) |logline| {
        try stdout.print("{s} {s} [{s}] {s}\n", .{ logline.date, logline.time, logline.level, logline.message });
    }
    try stdout.flush();
}
