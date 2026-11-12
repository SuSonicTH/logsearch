const std = @import("std");
const LogSearch = @import("LogSearch.zig");
const LogReader = @import("LogReader.zig");
const Arguments = @import("Arguments.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try castArgs(try init.minimal.args.toSlice(init.arena.allocator()), allocator);
    defer allocator.free(args);

    var options = LogSearch.Options.init(allocator);
    defer options.deinit();

    try Arguments.parse(init.io, &options, args);

    var matcher = LogReader.Matcher.compile(&options.pattern) catch |err| switch (err) {
        error.InvalidPatternOrder => try Arguments.exitError(
            init.io,
            "error: --patternOrder must be a permutation of 'tlc'\n",
            .{},
        ),
        error.PatternTooLong => try Arguments.exitError(
            init.io,
            "error: combined log pattern is too long\n",
            .{},
        ),
        error.InvalidLinePattern => try Arguments.exitError(
            init.io,
            "error: invalid combined log pattern\n",
            .{},
        ),
        error.InvalidTimePattern => try Arguments.exitError(
            init.io,
            "error: invalid --timePattern regex '{s}'\n",
            .{options.pattern.time},
        ),
        error.InvalidLevelPattern => try Arguments.exitError(
            init.io,
            "error: invalid --levelPattern regex '{s}'\n",
            .{options.pattern.level},
        ),
        error.InvalidClassPattern => try Arguments.exitError(
            init.io,
            "error: invalid --classPattern regex '{s}'\n",
            .{options.pattern.class},
        ),
    };
    var logSearch = LogSearch.init(init.io, &options, &matcher);
    defer logSearch.deinit();

    try logSearch.run();
}

fn castArgs(args: []const [:0]const u8, allocator: std.mem.Allocator) ![]const []const u8 {
    const ret = try allocator.alloc([]const u8, args.len);
    for (args, 0..) |arg, i| {
        ret[i] = arg;
    }
    return ret;
}

test {
    _ = @import("Arguments.zig");
    _ = @import("LogReader.zig");
    _ = @import("LogSearch.zig");
    _ = @import("Manual.zig");
    _ = @import("Prefilter.zig");
    _ = @import("TimeRange.zig");
}
