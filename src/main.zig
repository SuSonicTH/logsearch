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

    var matcher = try LogReader.Matcher.compile(&options.pattern);
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
