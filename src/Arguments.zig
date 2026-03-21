const std = @import("std");
const LogSearch = @import("LogSearch.zig");

const Argument = enum {
    @"--help",
    @"--version",
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

const version = "logsearch 0.1";
const help = @embedFile("USAGE.txt");
const license = @embedFile("LICENSE.txt");

var skip_next: bool = false;

pub fn parse(options: *LogSearch.Options, args: [][]const u8) !void {
    for (args[1..], 1..) |arg, index| {
        if (skip_next) {
            skip_next = false;
            continue;
        }
        if (arg[0] == '-') {
            switch (std.meta.stringToEnum(Argument, arg) orelse {
                try exitError("error: argument {d} is unknown '{s}'\n", .{ index, arg });
            }) {
                .@"--help" => try printInfoAndExit(version ++ "\n" ++ help),
                .@"--version" => try printInfoAndExit(version ++ "\n\n" ++ license),
                .@"--level", .@"-l" => try options.addLevel(try argumentValue(args, index, arg)),
                .@"--search", .@"-s" => try options.addExpression(try argumentValue(args, index, arg)),
                .@"--class", .@"-c" => try options.addClass(try argumentValue(args, index, arg)),
                .@"--timePattern" => options.pattern.time = try argumentValue(args, index, arg),
                .@"--levelPattern" => options.pattern.level = try argumentValue(args, index, arg),
                .@"--classPattern" => options.pattern.class = try argumentValue(args, index, arg),
                .@"--patternOrder" => options.pattern.order = try argumentValue(args, index, arg),
                .@"--outputLines" => options.outputLines = true,
            }
        } else {
            try options.addFile(arg);
        }
    }

    if (options.files == null) {
        try exitError("error: missing file argument\n", .{});
    }
}

fn argumentValue(args: [][]const u8, index: usize, argument: []const u8) ![]const u8 {
    const pos = index + 1;
    if (pos >= args.len) {
        try exitError("value for argument '{s}' is missing", .{argument});
    }
    skip_next = true;
    return args[pos];
}

fn printInfoAndExit(info: []const u8) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    _ = try stdout.write(info);
    try stdout.flush();
    std.process.exit(0);
}

fn exitError(comptime message: []const u8, args: anytype) !noreturn {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    try stderr.print(message, args);
    try stderr.flush();
    std.process.exit(1);
}
