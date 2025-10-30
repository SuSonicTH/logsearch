const std = @import("std");
const builtin = @import("builtin");
const memMapper = @import("memMapper").MemMapper;
const mvzr = @import("mvzr");

pub fn main() !void {
    //    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    //    const allocator, const is_debug = gpa: {
    //        break :gpa switch (builtin.mode) {
    //            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
    //            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
    //        };
    //    };
    //    defer if (is_debug) {
    //        _ = debug_allocator.deinit();
    //    };

    var logIter = try LogReader.init("logs/BlackMed.log");
    defer logIter.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    while (logIter.next()) |logline| {
        try stdout.print("{s} {s} [{s}] {s}\n", .{ logline.date, logline.time, logline.level, logline.message });
    }
    try stdout.flush();
}

const LogReader = struct {
    file: std.fs.File,
    mapper: memMapper,
    data: []const u8,
    pos: u64 = 0,
    regex: mvzr.Regex,

    pub fn init(fileName: []const u8) !LogReader {
        const file = try std.fs.cwd().openFile(fileName, .{});
        errdefer file.close();

        var mapper = try memMapper.init(file, false);
        errdefer mapper.deinit();

        return .{
            .file = file,
            .mapper = mapper,
            .data = try mapper.map(u8, .{}),
            .regex = mvzr.compile("^\\d\\d\\d\\d-\\d\\d-\\d\\d \\d\\d:\\d\\d:\\d\\d,\\d\\d\\d \\[[A-Za-z]+\\]").?,
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
            if (pos >= self.data.len or self.regex.isMatch(self.data[pos..])) {
                const line = self.getLineUpdatePos(pos);
                const match = self.regex.match(line).?;
                return LogLine.get(line, match);
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
};

const LogLine = struct {
    line: []const u8,
    prefix: []const u8,
    date: []const u8,
    time: []const u8,
    timeStamp: []const u8,
    level: []const u8,
    message: []const u8,

    pub fn get(line: []const u8, match: mvzr.Match) LogLine {
        return .{
            .line = line,
            .prefix = match.slice,
            .message = line[match.slice.len + 1 ..],
            .date = line[0..10],
            .time = line[11..23],
            .timeStamp = line[0..23],
            .level = line[25 .. match.slice.len - 1],
        };
    }
};
