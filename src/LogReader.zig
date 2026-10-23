const std = @import("std");
const mvzr = @import("mvzr");

const LogReader = @This();

io: std.Io,
file: std.Io.File,
memory_map: ?std.Io.File.MemoryMap,
data: []const u8,
pos: u64 = 0,
matcher: *LogReader.Matcher,

pub fn init(io: std.Io, fileName: []const u8, matcher: *LogReader.Matcher) !LogReader {
    const file = try std.Io.Dir.cwd().openFile(io, fileName, .{});
    errdefer file.close(io);

    const size = (try file.stat(io)).size;
    if (size == 0) {
        return .{
            .io = io,
            .file = file,
            .memory_map = null,
            .data = &.{},
            .matcher = matcher,
        };
    }

    var memory_map = try file.createMemoryMap(io, .{
        .len = @intCast(size),
        .protection = .{ .read = true },
        .populate = false,
    });
    errdefer memory_map.destroy(io);

    return .{
        .io = io,
        .file = file,
        .memory_map = memory_map,
        .data = memory_map.memory,
        .matcher = matcher,
    };
}

pub fn deinit(self: *LogReader) void {
    if (self.memory_map) |*memory_map| {
        memory_map.destroy(self.io);
    }
    self.file.close(self.io);
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
        var writer = std.Io.Writer.fixed(&self.buffer);

        for (self.order, 0..) |patternType, index| {
            if (index > 0) try writer.writeByte(' ');
            switch (patternType) {
                't' => try writer.writeAll(self.time),
                'l' => try writer.writeAll(self.level),
                'c' => try writer.writeAll(self.class),
                else => @panic("unknown pattern type"),
            }
        }

        return writer.buffered();
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

test "line pattern" {
    var pattern: Pattern = .{};
    const actual = try pattern.getLinePattern();
    try std.testing.expectEqualStrings(
        "^\\d\\d\\d\\d-\\d\\d-\\d\\d \\d\\d:\\d\\d:\\d\\d,\\d\\d\\d \\[[A-Za-z]+\\] [^ ]+",
        actual,
    );
}

test "parse log line" {
    var pattern: Pattern = .{};
    var matcher = try Matcher.compile(&pattern);
    const parsed = LogLine.get("2024-01-01 12:00:01,000 [ERROR] com.example.Db connection failed", &matcher);
    try std.testing.expectEqualStrings("[ERROR]", parsed.level);
    try std.testing.expectEqualStrings("com.example.Db", parsed.class);
    try std.testing.expectEqualStrings("connection failed", parsed.message);
}

test "iterate log lines" {
    var pattern: Pattern = .{};
    var matcher = try Matcher.compile(&pattern);
    const data =
        "2024-01-01 12:00:00,000 [INFO] com.example.App started\n" ++
        "2024-01-01 12:00:01,000 [ERROR] com.example.Db connection failed\n" ++
        "2024-01-01 12:00:02,000 [DEBUG] com.example.App tick\n";
    var reader = LogReader{
        .io = std.testing.io,
        .file = undefined,
        .memory_map = null,
        .data = data,
        .matcher = &matcher,
    };
    const first = reader.next().?;
    try std.testing.expectEqualStrings("[INFO]", first.level);
    try std.testing.expectEqualStrings("com.example.App", first.class);
    const second = reader.next().?;
    try std.testing.expectEqualStrings("[ERROR]", second.level);
    try std.testing.expectEqualStrings("com.example.Db", second.class);
    const third = reader.next().?;
    try std.testing.expectEqualStrings("[DEBUG]", third.level);
    try std.testing.expectEqualStrings("com.example.App", third.class);
    try std.testing.expect(reader.next() == null);
}
