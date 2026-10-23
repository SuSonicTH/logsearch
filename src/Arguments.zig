const std = @import("std");
const LogSearch = @import("LogSearch.zig");
const Manual = @import("Manual.zig");
const license = @import("license");

const Argument = enum {
    @"--help",
    @"--version",
    @"--show-manual",
    @"--level",
    @"-l",
    @"--search",
    @"-s",
    @"--class",
    @"-c",
    @"--timePattern",
    @"--levelPattern",
    @"--classPattern",
    @"--patternOrder",
    @"--outputLines",
};

const version = "logsearch 0.2";
const help = @embedFile("USAGE.txt");

var skip_next: bool = false;

pub fn parse(io: std.Io, options: *LogSearch.Options, args: []const []const u8) !void {
    for (args[1..], 1..) |arg, index| {
        if (skip_next) {
            skip_next = false;
            continue;
        }
        if (arg[0] == '-') {
            switch (std.meta.stringToEnum(Argument, arg) orelse {
                try exitError(io, "error: argument {d} is unknown '{s}'\n", .{ index, arg });
            }) {
                .@"--help" => try printInfoAndExit(io, version ++ "\n" ++ help),
                .@"--version" => try printInfoAndExit(io, version ++ "\n\n" ++ license.text),
                .@"--show-manual" => {
                    try Manual.show(io);
                    std.process.exit(0);
                },
                .@"--level", .@"-l" => try options.addLevel(try argumentValue(io, args, index, arg)),
                .@"--search", .@"-s" => try options.addExpression(try argumentValue(io, args, index, arg)),
                .@"--class", .@"-c" => try options.addClass(try argumentValue(io, args, index, arg)),
                .@"--timePattern" => options.pattern.time = try argumentValue(io, args, index, arg),
                .@"--levelPattern" => options.pattern.level = try argumentValue(io, args, index, arg),
                .@"--classPattern" => options.pattern.class = try argumentValue(io, args, index, arg),
                .@"--patternOrder" => options.pattern.order = try argumentValue(io, args, index, arg),
                .@"--outputLines" => options.outputLines = true,
            }
        } else {
            try options.addFile(arg);
        }
    }

    if (options.files == null) {
        try exitError(io, "error: missing file argument\n", .{});
    }
}

fn argumentValue(io: std.Io, args: []const []const u8, index: usize, argument: []const u8) ![]const u8 {
    const pos = index + 1;
    if (pos >= args.len) {
        try exitError(io, "value for argument '{s}' is missing", .{argument});
    }
    skip_next = true;
    return args[pos];
}

fn printInfoAndExit(io: std.Io, info: []const u8) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    _ = try stdout.writeAll(info);
    try stdout.flush();
    std.process.exit(0);
}

fn exitError(io: std.Io, comptime message: []const u8, args: anytype) !noreturn {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    try stderr.print(message, args);
    try stderr.flush();
    std.process.exit(1);
}

test "parse level" {
    var options = LogSearch.Options.init(std.testing.allocator);
    defer options.deinit();
    const args = [_][]const u8{ "logsearch", "-l", "[ERROR]", "file.log" };
    try parse(std.testing.io, &options, &args);
    try std.testing.expectEqual(1, options.levels.?.items.len);
    try std.testing.expectEqualStrings("[ERROR]", options.levels.?.items[0]);
    try std.testing.expectEqual(1, options.files.?.items.len);
}
