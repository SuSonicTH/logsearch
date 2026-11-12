const std = @import("std");
const LogSearch = @import("LogSearch.zig");
const Manual = @import("Manual.zig");
const TimeRange = @import("TimeRange.zig").TimeRange;
const build_options = @import("build_options");
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
    @"--start",
    @"--end",
    @"--timePattern",
    @"--levelPattern",
    @"--classPattern",
    @"--patternOrder",
    @"--outputLines",
};

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
                .@"--help" => try printInfoAndExit(io, "logsearch " ++ build_options.version ++ "\n" ++ help),
                .@"--version" => try printInfoAndExit(
                    io,
                    "logsearch " ++ build_options.version ++ "\n\n" ++ license.text,
                ),
                .@"--show-manual" => {
                    try Manual.show(io);
                    std.process.exit(0);
                },
                .@"--level", .@"-l" => try options.addLevel(try argumentValue(io, args, index, arg)),
                .@"--search", .@"-s" => {
                    const value = try argumentValue(io, args, index, arg);
                    options.addExpression(value) catch |err| switch (err) {
                        error.InvalidRegex => try exitError(io, "error: invalid --search regex '{s}'\n", .{value}),
                        else => return err,
                    };
                },
                .@"--class", .@"-c" => try options.addClass(try argumentValue(io, args, index, arg)),
                .@"--start" => {
                    if (options.range.start != null) {
                        try exitError(io, "error: --start specified more than once\n", .{});
                    }
                    const value = try argumentValue(io, args, index, arg);
                    options.range.start = TimeRange.parseStart(value) catch {
                        try exitError(
                            io,
                            "error: invalid --start datetime '{s}' " ++
                                "(expected YYYY-MM, YYYY-MM-DD, or YYYY-MM-DD HH[:MM[:SS]])\n",
                            .{value},
                        );
                    };
                },
                .@"--end" => {
                    if (options.range.end != null) {
                        try exitError(io, "error: --end specified more than once\n", .{});
                    }
                    const value = try argumentValue(io, args, index, arg);
                    options.range.end = TimeRange.parseEnd(value) catch {
                        try exitError(
                            io,
                            "error: invalid --end datetime '{s}' " ++
                                "(expected YYYY-MM, YYYY-MM-DD, or YYYY-MM-DD HH[:MM[:SS]])\n",
                            .{value},
                        );
                    };
                },
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

    if (!isValidPatternOrder(options.pattern.order)) {
        try exitError(io, "error: --patternOrder must be a permutation of 'tlc'\n", .{});
    }

    if (options.range.start) |start| {
        if (options.range.end) |end| {
            if (start > end) {
                try exitError(io, "error: --start is later than --end\n", .{});
            }
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

fn isValidPatternOrder(order: []const u8) bool {
    if (order.len != 3) return false;

    var seen_t = false;
    var seen_l = false;
    var seen_c = false;

    for (order) |c| {
        switch (c) {
            't' => {
                if (seen_t) return false;
                seen_t = true;
            },
            'l' => {
                if (seen_l) return false;
                seen_l = true;
            },
            'c' => {
                if (seen_c) return false;
                seen_c = true;
            },
            else => return false,
        }
    }

    return seen_t and seen_l and seen_c;
}

fn printInfoAndExit(io: std.Io, info: []const u8) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    _ = try stdout.writeAll(info);
    try stdout.flush();
    std.process.exit(0);
}

pub fn exitError(io: std.Io, comptime message: []const u8, args: anytype) !noreturn {
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

test "parse time range" {
    var options = LogSearch.Options.init(std.testing.allocator);
    defer options.deinit();
    const args = [_][]const u8{ "logsearch", "--start", "2025-10-19", "--end", "2025-10-19 23:59", "file.log" };
    try parse(std.testing.io, &options, &args);
    try std.testing.expectEqual(try TimeRange.parseStart("2025-10-19"), options.range.start.?);
    try std.testing.expectEqual(try TimeRange.parseEnd("2025-10-19 23:59"), options.range.end.?);
    try std.testing.expectEqual(1, options.files.?.items.len);
}

test "pattern order validation" {
    try std.testing.expect(isValidPatternOrder("tlc"));
    try std.testing.expect(isValidPatternOrder("ltc"));
    try std.testing.expect(isValidPatternOrder("ctl"));
    try std.testing.expect(!isValidPatternOrder("tlc "));
    try std.testing.expect(!isValidPatternOrder("ttc"));
    try std.testing.expect(!isValidPatternOrder("tl"));
    try std.testing.expect(!isValidPatternOrder("tld"));
}
