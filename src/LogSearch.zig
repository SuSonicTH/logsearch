const std = @import("std");
const LogReader = @import("LogReader.zig");
const mvzr = @import("mvzr");
const Prefilter = @import("Prefilter.zig").Prefilter;
const TimeRange = @import("TimeRange.zig").TimeRange;

const LogSearch = @This();
io: std.Io,
options: *Options,
matcher: *LogReader.Matcher,

pub fn init(io: std.Io, options: *Options, matcher: *LogReader.Matcher) LogSearch {
    return .{
        .io = io,
        .options = options,
        .matcher = matcher,
    };
}

pub fn deinit(self: *LogSearch) void {
    _ = self;
}

const line_separator = "--------------------------------------------------------------------------------\n";

pub fn run(self: *LogSearch) !void {
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(self.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    // Avoid parsing entries at all when no field filters are active.
    const filtered = self.options.levels != null or
        self.options.classes != null or
        self.options.expressions != null or
        self.options.range.isActive();

    for (self.options.files.?.items) |fileName| {
        // Files rotated with a YYYY-MM-DD suffix can be skipped without
        // opening them when the whole day is outside the requested range.
        if (self.options.range.shouldSkipFile(fileName)) continue;

        var logIter = try LogReader.init(self.io, fileName, self.matcher);
        defer logIter.deinit();

        var blocks: usize = 0;
        var parsed_entries: usize = 0;

        while (logIter.next()) |line| {
            blocks += 1;
            if (filtered) {
                const logline = LogReader.LogLine.get(line, self.matcher) orelse continue;
                parsed_entries += 1;
                const time_matches = self.timeMatches(logline.time) catch {
                    try stdout.flush();
                    self.fail(
                        "error: could not parse timestamp '{s}' in '{s}' for --start/--end\n",
                        .{ logline.time, fileName },
                    );
                };
                if (!time_matches) continue;
                if (!self.levelMatches(logline.level)) continue;
                if (!self.classMatches(logline.class)) continue;
                if (!self.messageMatches(logline.message)) continue;
            }
            try stdout.writeAll(line);
            try stdout.writeByte('\n');
            if (self.options.outputLines) try stdout.writeAll(line_separator);
        }

        if (self.options.range.isActive() and blocks > 0 and parsed_entries == 0) {
            try stdout.flush();
            self.fail(
                "error: no entries matched the configured log/time pattern in '{s}'\n",
                .{fileName},
            );
        }
    }
    try stdout.flush();
}

inline fn timeMatches(self: *LogSearch, time: []const u8) !bool {
    if (!self.options.range.isActive()) return true;
    const key = TimeRange.timestampKey(time) orelse return error.InvalidLogTimestamp;
    return self.options.range.contains(key);
}

fn fail(self: *LogSearch, comptime message: []const u8, args: anytype) noreturn {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(self.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    stderr.print(message, args) catch {};
    stderr.flush() catch {};
    std.process.exit(1);
}

inline fn levelMatches(self: *LogSearch, level: []const u8) bool {
    if (self.options.levels) |levels| {
        for (levels.items) |expectedLevel| {
            if (levelEql(expectedLevel, level)) {
                return true;
            }
        }
        return false;
    }
    return true;
}

/// Compares level names independently of the surrounding brackets. With the
/// default level pattern the captured level is `[ERROR]`, but users commonly
/// pass just `ERROR` (and custom patterns may capture either form).
fn levelEql(expected: []const u8, actual: []const u8) bool {
    if (std.mem.eql(u8, expected, actual)) return true;
    return std.mem.eql(u8, withoutBrackets(expected), withoutBrackets(actual));
}

fn withoutBrackets(level: []const u8) []const u8 {
    if (level.len >= 3 and level[0] == '[' and level[level.len - 1] == ']') {
        return level[1 .. level.len - 1];
    }
    return level;
}

inline fn classMatches(self: *LogSearch, class: []const u8) bool {
    if (self.options.classes) |classes| {
        for (classes.items) |expectedClass| {
            if (std.mem.eql(u8, expectedClass, class)) {
                return true;
            }
        }
        return false;
    }
    return true;
}

inline fn messageMatches(self: *LogSearch, message: []const u8) bool {
    if (self.options.expressions) |expressions| {
        for (expressions.items) |*expression| {
            if (expression.prefilter.matches(message)) {
                // For anchor-free literal patterns the prefilter is exact and
                // the regex engine does not need to run at all.
                if (expression.prefilter.exact or expression.regex.isMatch(message)) {
                    return true;
                }
            }
        }
        return false;
    }
    return true;
}

pub const Expression = struct {
    regex: mvzr.Regex,
    prefilter: Prefilter,
};

pub const Options = struct {
    allocator: std.mem.Allocator,
    levels: ?std.ArrayList([]const u8) = null,
    classes: ?std.ArrayList([]const u8) = null,
    expressions: ?std.ArrayList(Expression) = null,
    files: ?std.ArrayList([]const u8) = null,
    pattern: LogReader.Pattern = .{},
    range: TimeRange = .{},
    outputLines: bool = false,

    pub fn init(allocator: std.mem.Allocator) Options {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Options) void {
        if (self.levels) |*levels| {
            levels.deinit(self.allocator);
        }
        if (self.files) |*files| {
            files.deinit(self.allocator);
        }
        if (self.expressions) |*expressions| {
            for (expressions.items) |expression| {
                expression.prefilter.deinit(self.allocator);
            }
            expressions.deinit(self.allocator);
        }
        if (self.classes) |*classes| {
            classes.deinit(self.allocator);
        }
    }

    pub fn addLevel(self: *Options, level: []const u8) !void {
        if (self.levels == null) {
            self.levels = .empty;
        }
        try self.levels.?.append(self.allocator, level);
    }

    pub fn addClass(self: *Options, class: []const u8) !void {
        if (self.classes == null) {
            self.classes = .empty;
        }
        try self.classes.?.append(self.allocator, class);
    }

    pub fn addExpression(self: *Options, regex: []const u8) !void {
        const compiled = mvzr.compile(regex) orelse return error.InvalidRegex;
        var prefilter = try Prefilter.analyze(self.allocator, regex);
        errdefer prefilter.deinit(self.allocator);

        if (self.expressions == null) {
            self.expressions = .empty;
        }
        try self.expressions.?.append(self.allocator, .{
            .regex = compiled,
            .prefilter = prefilter,
        });
    }

    pub fn addFile(self: *Options, file: []const u8) !void {
        if (self.files == null) {
            self.files = .empty;
        }
        try self.files.?.append(self.allocator, file);
    }
};

test "invalid search regex is rejected" {
    var options = Options.init(std.testing.allocator);
    defer options.deinit();
    try std.testing.expectError(error.InvalidRegex, options.addExpression("["));
}

test "level filtering" {
    var options = Options.init(std.testing.allocator);
    defer options.deinit();
    try options.addLevel("[ERROR]");
    try std.testing.expectEqual(1, options.levels.?.items.len);
    var search = LogSearch.init(std.testing.io, &options, undefined);
    try std.testing.expect(search.levelMatches("[ERROR]"));
    try std.testing.expect(search.levelMatches("ERROR"));
    try std.testing.expect(!search.levelMatches("[INFO]"));
}

test "level filtering accepts brackets in expected value" {
    var options = Options.init(std.testing.allocator);
    defer options.deinit();
    try options.addLevel("WARN");
    var search = LogSearch.init(std.testing.io, &options, undefined);
    try std.testing.expect(search.levelMatches("[WARN]"));
    try std.testing.expect(search.levelMatches("WARN"));
    try std.testing.expect(!search.levelMatches("[ERROR]"));
    try std.testing.expect(!search.levelMatches("ERROR"));
}

test "time range filtering includes boundaries" {
    var options = Options.init(std.testing.allocator);
    defer options.deinit();
    options.range = try TimeRange.init("2025-10-19", "2025-10-19");
    var search = LogSearch.init(std.testing.io, &options, undefined);

    try std.testing.expect(try search.timeMatches("2025-10-19 00:00:00,000"));
    try std.testing.expect(try search.timeMatches("2025-10-19 23:59:59,999"));
    try std.testing.expect(!try search.timeMatches("2025-10-18 23:59:59,999"));
    try std.testing.expect(!try search.timeMatches("2025-10-20 00:00:00,000"));
}

test "time range filtering requires parseable timestamps" {
    var options = Options.init(std.testing.allocator);
    defer options.deinit();
    options.range = try TimeRange.init("2025-10-19", null);
    var search = LogSearch.init(std.testing.io, &options, undefined);

    try std.testing.expectError(error.InvalidLogTimestamp, search.timeMatches("not a timestamp"));
}

test "time range filtering is disabled without bounds" {
    var options = Options.init(std.testing.allocator);
    defer options.deinit();
    var search = LogSearch.init(std.testing.io, &options, undefined);

    try std.testing.expect(try search.timeMatches("not a timestamp"));
}
