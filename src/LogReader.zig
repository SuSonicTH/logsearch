const std = @import("std");
const builtin = @import("builtin");
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
    adviseSequential(memory_map.memory);

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

/// Tell the kernel that the mapping is read sequentially. This encourages
/// read-ahead and lets the kernel drop pages we have already passed instead
/// of keeping the whole logfile resident.
fn adviseSequential(memory: []align(std.heap.page_size_min) u8) void {
    if (comptime builtin.os.tag == .windows) return;
    std.posix.madvise(memory.ptr, memory.len, std.posix.MADV.SEQUENTIAL) catch {};
}

pub fn next(self: *LogReader) ?[]const u8 {
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
        if (pos >= self.data.len or self.isEntryStart(pos)) {
            return self.getLineUpdatePos(pos);
        }
    }
}

inline fn isEntryStart(self: *LogReader, pos: usize) bool {
    // The default line pattern starts with a fixed-width timestamp, so the
    // regex can be replaced by a handful of byte comparisons.
    if (self.matcher.fast) {
        return isTimestamp(self.data[pos..]) and parseFast(self.data[pos..]) != null;
    }
    return self.matcher.line.isMatch(self.data[pos..]);
}

fn getLineUpdatePos(self: *LogReader, pos: usize) []const u8 {
    const start = self.pos;
    self.pos = pos;
    var end = pos;
    if (self.data[pos - 1] == '\n') end -= 1;

    return self.data[start..end];
}

pub const Pattern = struct {
    buffer: [4096]u8 = undefined,
    time: []const u8 = default_time,
    level: []const u8 = default_level,
    class: []const u8 = default_class,
    order: []const u8 = "tlc",

    const default_time = "^\\d\\d\\d\\d-\\d\\d-\\d\\d \\d\\d:\\d\\d:\\d\\d,\\d\\d\\d";
    const default_level = "\\[[A-Za-z]+\\]";
    const default_class = "[^ ]+";

    fn isDefault(self: *const Pattern) bool {
        return std.mem.eql(u8, self.time, default_time) and
            std.mem.eql(u8, self.level, default_level) and
            std.mem.eql(u8, self.class, default_class) and
            std.mem.eql(u8, self.order, "tlc");
    }

    fn getLinePattern(self: *Pattern) ![]const u8 {
        var writer = std.Io.Writer.fixed(&self.buffer);

        // Entry detection is always performed at the start of a line. Anchor
        // the combined pattern once and strip the anchor from the first
        // component (or from any component that carries one), so that a
        // `^` never ends up in the middle of the combined pattern.
        try writer.writeByte('^');
        for (self.order, 0..) |patternType, index| {
            if (index > 0) try writer.writeByte(' ');
            const component = switch (patternType) {
                't' => self.time,
                'l' => self.level,
                'c' => self.class,
                else => @panic("unknown pattern type"),
            };
            if (component.len > 0 and component[0] == '^') {
                try writer.writeAll(component[1..]);
            } else {
                try writer.writeAll(component);
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
    /// True when the patterns and order are the built-in defaults, which
    /// allows the much cheaper hand-written parser to be used.
    fast: bool,

    pub fn compile(pattern: *Pattern) !Matcher {
        return .{
            .line = mvzr.compile(try pattern.getLinePattern()).?,
            .time = mvzr.compile(pattern.time).?,
            .level = mvzr.compile(pattern.level).?,
            .class = mvzr.compile(pattern.class).?,
            .order = pattern.order,
            .fast = pattern.isDefault(),
        };
    }
};

pub const LogLine = struct {
    line: []const u8,
    level: []const u8,
    class: []const u8,
    message: []const u8,

    pub fn get(line: []const u8, matcher: *LogReader.Matcher) LogLine {
        if (matcher.fast and isTimestamp(line)) {
            if (parseFast(line)) |fields| {
                return .{
                    .line = line,
                    .level = fields.level,
                    .class = fields.class,
                    .message = fields.message,
                };
            }
        }
        return getRegex(line, matcher);
    }

    /// Fast path for the built-in `tlc` layout:
    /// `YYYY-MM-DD HH:MM:SS,mmm [LEVEL] class message`
    fn getRegex(line: []const u8, matcher: *LogReader.Matcher) LogLine {
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

/// Checks for the fixed-width default timestamp prefix used by the built-in
/// pattern: `YYYY-MM-DD HH:MM:SS,mmm`.
fn isTimestamp(line: []const u8) bool {
    if (line.len < 23) return false;
    return isDigit(line[0]) and isDigit(line[1]) and isDigit(line[2]) and isDigit(line[3]) and
        line[4] == '-' and isDigit(line[5]) and isDigit(line[6]) and
        line[7] == '-' and isDigit(line[8]) and isDigit(line[9]) and
        line[10] == ' ' and isDigit(line[11]) and isDigit(line[12]) and
        line[13] == ':' and isDigit(line[14]) and isDigit(line[15]) and
        line[16] == ':' and isDigit(line[17]) and isDigit(line[18]) and
        line[19] == ',' and isDigit(line[20]) and isDigit(line[21]) and isDigit(line[22]);
}

const FastFields = struct {
    level: []const u8,
    class: []const u8,
    message: []const u8,
};

fn parseFast(line: []const u8) ?FastFields {
    if (line.len < 25 or line[23] != ' ') return null;

    var pos: usize = 24;
    if (line[pos] != '[') return null;
    const close = std.mem.indexOfScalarPos(u8, line, pos, ']') orelse return null;
    if (close == pos + 1) return null; // `+` requires at least one letter
    for (line[pos + 1 .. close]) |c| {
        if (!std.ascii.isAlphabetic(c)) return null;
    }
    const level = line[pos .. close + 1];

    if (close + 1 >= line.len or line[close + 1] != ' ') return null;
    pos = close + 2;
    const class_end = std.mem.indexOfScalarPos(u8, line, pos, ' ') orelse line.len;
    if (class_end == pos) return null; // `+` requires at least one char
    const class = line[pos..class_end];

    const message = if (class_end < line.len) line[class_end + 1 ..] else "";
    return .{ .level = level, .class = class, .message = message };
}

inline fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

test "line pattern" {
    var pattern: Pattern = .{};
    const actual = try pattern.getLinePattern();
    try std.testing.expectEqualStrings(
        "^\\d\\d\\d\\d-\\d\\d-\\d\\d \\d\\d:\\d\\d:\\d\\d,\\d\\d\\d \\[[A-Za-z]+\\] [^ ]+",
        actual,
    );
}

test "line pattern is always anchored" {
    var pattern: Pattern = .{ .order = "ltc" };
    const actual = try pattern.getLinePattern();
    try std.testing.expectEqualStrings(
        "^\\[[A-Za-z]+\\] \\d\\d\\d\\d-\\d\\d-\\d\\d \\d\\d:\\d\\d:\\d\\d,\\d\\d\\d [^ ]+",
        actual,
    );
    _ = try Matcher.compile(&pattern);
}

test "parse log line" {
    var pattern: Pattern = .{};
    var matcher = try Matcher.compile(&pattern);
    const parsed = LogLine.get("2024-01-01 12:00:01,000 [ERROR] com.example.Db connection failed", &matcher);
    try std.testing.expectEqualStrings("[ERROR]", parsed.level);
    try std.testing.expectEqualStrings("com.example.Db", parsed.class);
    try std.testing.expectEqualStrings("connection failed", parsed.message);
}

test "fast parse matches regex parser" {
    var pattern: Pattern = .{};
    var matcher = try Matcher.compile(&pattern);
    const lines = [_][]const u8{
        "2024-01-01 12:00:01,000 [ERROR] com.example.Db connection failed",
        "2024-01-01 12:00:01,000 [INFO] a.b  message with leading space",
        "2024-01-01 12:00:01,000 [WARN] clazz ",
        "2024-01-01 12:00:01,000 [DEBUG] x",
    };
    for (lines) |line| {
        const fast = LogLine.get(line, &matcher);
        const slow = LogLine.getRegex(line, &matcher);
        try std.testing.expectEqualStrings(slow.level, fast.level);
        try std.testing.expectEqualStrings(slow.class, fast.class);
        try std.testing.expectEqualStrings(slow.message, fast.message);
    }
}

test "timestamp without level is a continuation" {
    var pattern: Pattern = .{};
    var matcher = try Matcher.compile(&pattern);
    const data =
        "2024-01-01 12:00:00,000 [INFO] com.example.App started\n" ++
        "2024-01-01 12:00:01,000 no level or class here\n" ++
        "2024-01-01 12:00:02,000 [DEBUG] com.example.App tick\n";
    var reader = LogReader{
        .io = std.testing.io,
        .file = undefined,
        .memory_map = null,
        .data = data,
        .matcher = &matcher,
    };
    const first = reader.next().?;
    try std.testing.expectEqualStrings(
        "2024-01-01 12:00:00,000 [INFO] com.example.App started\n" ++
            "2024-01-01 12:00:01,000 no level or class here",
        first,
    );
    const second = reader.next().?;
    try std.testing.expectEqualStrings("2024-01-01 12:00:02,000 [DEBUG] com.example.App tick", second);
    try std.testing.expect(reader.next() == null);
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
    const first = LogLine.get(reader.next().?, &matcher);
    try std.testing.expectEqualStrings("[INFO]", first.level);
    try std.testing.expectEqualStrings("com.example.App", first.class);
    const second = LogLine.get(reader.next().?, &matcher);
    try std.testing.expectEqualStrings("[ERROR]", second.level);
    try std.testing.expectEqualStrings("com.example.Db", second.class);
    const third = LogLine.get(reader.next().?, &matcher);
    try std.testing.expectEqualStrings("[DEBUG]", third.level);
    try std.testing.expectEqualStrings("com.example.App", third.class);
    try std.testing.expect(reader.next() == null);
}
