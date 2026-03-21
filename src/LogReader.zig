const std = @import("std");
const MemMapper = @import("memMapper").MemMapper;
const mvzr = @import("mvzr");

const LogReader = @This();

file: std.fs.File,
mapper: MemMapper,
data: []const u8,
pos: u64 = 0,
matcher: *LogReader.Matcher,

pub fn init(fileName: []const u8, matcher: *LogReader.Matcher) !LogReader {
    const file = try std.fs.cwd().openFile(fileName, .{});
    errdefer file.close();

    var mapper = try MemMapper.init(file, false);
    errdefer mapper.deinit();

    return .{
        .file = file,
        .mapper = mapper,
        .data = try mapper.map(u8, .{}),
        .matcher = matcher,
    };
}

pub fn deinit(self: *LogReader) void {
    self.mapper.unmap(self.data);
    self.mapper.deinit();
    self.file.close();
}

pub fn next(self: *LogReader) ?LogLine {
    var pos = self.pos;
    if (self.pos >= self.data.len) {
        return null;
    }
    while (true) {
        while (pos < self.data.len and self.data[pos] != '\n') {
            pos += 1;
        }
        if (pos < self.data.len) {
            pos += 1;
        }
        if (pos >= self.data.len or self.matcher.line.isMatch(self.data[pos..])) {
            const line = self.getLineUpdatePos(pos);
            return LogLine.get(line, self.matcher);
        }
    }
}

fn getLineUpdatePos(self: *LogReader, pos: u64) []const u8 {
    const start = self.pos;
    self.pos = pos;
    var end = pos;
    if (self.data[pos - 1] == '\n') end -= 1;

    return self.data[start..end];
}

pub const Pattern = struct {
    buffer: [4096]u8 = undefined,
    time: []const u8 = "^\\d\\d\\d\\d-\\d\\d-\\d\\d \\d\\d:\\d\\d:\\d\\d,\\d\\d\\d",
    level: []const u8 = "\\[[A-Za-z]+\\]",
    class: []const u8 = "[^ ]+",
    order: []const u8 = "tlc",

    fn getLinePattern(self: *Pattern) ![]const u8 {
        var fba: std.heap.FixedBufferAllocator = .init(&self.buffer);
        const allocator = fba.allocator();

        var pattern = std.array_list.Managed(u8).init(allocator);
        defer pattern.deinit();

        for (self.order) |patternType| {
            switch (patternType) {
                't' => {
                    if (pattern.items.len > 0) try pattern.append(' ');
                    try pattern.appendSlice(self.time);
                },
                'l' => {
                    if (pattern.items.len > 0) try pattern.append(' ');
                    try pattern.appendSlice(self.level);
                },

                'c' => {
                    if (pattern.items.len > 0) try pattern.append(' ');
                    try pattern.appendSlice(self.class);
                },
                else => @panic("unknown pattern type"),
            }
        }

        return pattern.items;
    }
};

pub const Matcher = struct {
    line: mvzr.Regex,
    time: mvzr.Regex,
    level: mvzr.Regex,
    class: mvzr.Regex,
    order: []const u8,

    pub fn compile(pattern: *Pattern) !Matcher {
        return .{
            .line = mvzr.compile(try pattern.getLinePattern()).?,
            .time = mvzr.compile(pattern.time).?,
            .level = mvzr.compile(pattern.level).?,
            .class = mvzr.compile(pattern.class).?,
            .order = pattern.order,
        };
    }
};

pub const LogLine = struct {
    line: []const u8,
    level: []const u8,
    class: []const u8,
    message: []const u8,

    fn get(line: []const u8, matcher: *LogReader.Matcher) LogLine {
        var pos: usize = 0;

        var level: []const u8 = "";
        var class: []const u8 = "";

        for (matcher.order) |patternType| {
            switch (patternType) {
                't' => {
                    const match = matcher.time.match(line[pos..]).?;
                    pos += match.end + 1;
                },
                'c' => {
                    const match = matcher.class.match(line[pos..]).?;
                    class = match.slice;
                    pos += match.end + 1;
                },
                'l' => {
                    const match = matcher.level.match(line[pos..]).?;
                    level = match.slice;
                    pos += match.end + 1;
                },
                else => unreachable,
            }
        }

        return .{
            .line = line,
            .level = level,
            .class = class,
            .message = line[pos..],
        };
    }
};
