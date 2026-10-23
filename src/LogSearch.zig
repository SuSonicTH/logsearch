const std = @import("std");
const LogReader = @import("LogReader.zig");
const mvzr = @import("mvzr");

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

const line = "--------------------------------------------------------------------------------\n";

pub fn run(self: *LogSearch) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(self.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    for (self.options.files.?.items) |fileName| {
        var logIter = try LogReader.init(self.io, fileName, self.matcher);
        defer logIter.deinit();

        while (logIter.next()) |logline| {
            if (!self.levelMatches(logline.level)) continue;
            if (!self.classMatches(logline.class)) continue;
            if (!self.messageMatches(logline.message)) continue;
            try stdout.writeAll(logline.line);
            try stdout.writeAll("\n");
            if (self.options.outputLines) try stdout.writeAll(line);
            try stdout.flush();
        }
    }
    try stdout.flush();
}

inline fn levelMatches(self: *LogSearch, level: []const u8) bool {
    if (self.options.levels) |levels| {
        for (levels.items) |expectedLevel| {
            if (std.mem.eql(u8, expectedLevel, level)) {
                return true;
            }
        }
        return false;
    }
    return true;
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
        for (expressions.items) |expression| {
            if (expression.isMatch(message)) {
                return true;
            }
        }
        return false;
    }
    return true;
}

pub const Options = struct {
    allocator: std.mem.Allocator,
    levels: ?std.ArrayList([]const u8) = null,
    classes: ?std.ArrayList([]const u8) = null,
    expressions: ?std.ArrayList(mvzr.Regex) = null,
    files: ?std.ArrayList([]const u8) = null,
    pattern: LogReader.Pattern = .{},
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
        if (self.expressions == null) {
            self.expressions = .empty;
        }
        try self.expressions.?.append(self.allocator, mvzr.compile(regex).?);
    }

    pub fn addFile(self: *Options, file: []const u8) !void {
        if (self.files == null) {
            self.files = .empty;
        }
        try self.files.?.append(self.allocator, file);
    }
};

test "level filtering" {
    var options = Options.init(std.testing.allocator);
    defer options.deinit();
    try options.addLevel("[ERROR]");
    try std.testing.expectEqual(1, options.levels.?.items.len);
    var search = LogSearch.init(std.testing.io, &options, undefined);
    try std.testing.expect(search.levelMatches("[ERROR]"));
    try std.testing.expect(!search.levelMatches("[INFO]"));
}
