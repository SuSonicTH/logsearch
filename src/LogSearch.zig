const std = @import("std");
const LogReader = @import("LogReader.zig");
const mvzr = @import("mvzr");

const LogSearch = @This();
options: *Options,
matcher: *LogReader.Matcher,

pub fn init(options: *Options, matcher: *LogReader.Matcher) LogSearch {
    return .{
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
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    for (self.options.files.?.items) |fileName| {
        var logIter = try LogReader.init(fileName, self.matcher);
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
    levels: ?std.array_list.Managed([]const u8) = null,
    classes: ?std.array_list.Managed([]const u8) = null,
    expressions: ?std.array_list.Managed(mvzr.Regex) = null,
    files: ?std.array_list.Managed([]const u8) = null,
    pattern: LogReader.Pattern = .{},
    outputLines: bool = false,

    pub fn init(allocator: std.mem.Allocator) Options {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Options) void {
        if (self.levels) |levels| {
            levels.deinit();
        }
        if (self.files) |files| {
            files.deinit();
        }
        if (self.expressions) |expressions| {
            expressions.deinit();
        }
    }

    pub fn addLevel(self: *Options, level: []const u8) !void {
        if (self.levels == null) {
            self.levels = std.array_list.Managed([]const u8).init(self.allocator);
        }
        try self.levels.?.append(level);
    }

    pub fn addClass(self: *Options, class: []const u8) !void {
        if (self.classes == null) {
            self.classes = std.array_list.Managed([]const u8).init(self.allocator);
        }
        try self.classes.?.append(class);
    }

    pub fn addExpression(self: *Options, regex: []const u8) !void {
        if (self.expressions == null) {
            self.expressions = std.array_list.Managed(mvzr.Regex).init(self.allocator);
        }
        try self.expressions.?.append(mvzr.compile(regex).?);
    }

    pub fn addFile(self: *Options, file: []const u8) !void {
        if (self.files == null) {
            self.files = std.array_list.Managed([]const u8).init(self.allocator);
        }
        try self.files.?.append(file);
    }
};
