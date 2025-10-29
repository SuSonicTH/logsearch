const std = @import("std");
const memMapper = @import("memMapper").MemMapper;
const builtin = @import("builtin");

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

    const file = try std.fs.cwd().openFile("logs/BlackMed.log", .{});
    defer file.close();

    var mapper = try memMapper.init(file, false);
    defer mapper.deinit();

    const log = try mapper.map(u8, .{});
    defer mapper.unmap(log);

    var logIter = LogReader.init(log);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    while (logIter.next()) |logline| {
        try stdout.print("{s}\n", .{logline});
    }
    try stdout.flush();
}

const LogReader = struct {
    data: []const u8,
    pos: u64 = 0,

    pub fn init(data: []const u8) LogReader {
        return .{
            .data = data,
        };
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
            if (pos >= self.data.len) {
                const start = self.pos;
                self.pos = pos;

                var end = pos;
                if (self.data[pos - 1] == '\n') end -= 1;
                return self.data[start..end];
            }
            if (isLogStart(self.data[pos..])) {
                const start = self.pos;
                self.pos = pos;

                var end = pos;
                if (self.data[pos - 1] == '\n') end -= 1;
                return self.data[start..end];
            }
        }
    }

    inline fn isLogStart(line: []const u8) bool {
        if (line.len < 26) {
            return false;
        }

        if (line[0] < '0' or line[0] > '9') return false;
        if (line[1] < '0' or line[1] > '9') return false;
        if (line[2] < '0' or line[2] > '9') return false;
        if (line[3] < '0' or line[3] > '9') return false;

        if (line[4] != '-') return false;

        if (line[5] < '0' or line[5] > '9') return false;
        if (line[6] < '0' or line[6] > '9') return false;

        if (line[7] != '-') return false;

        if (line[8] < '0' or line[8] > '9') return false;
        if (line[9] < '0' or line[9] > '9') return false;

        if (line[10] != ' ') return false;

        if (line[11] < '0' or line[11] > '9') return false;
        if (line[12] < '0' or line[12] > '9') return false;

        if (line[13] != ':') return false;

        if (line[14] < '0' or line[14] > '9') return false;
        if (line[15] < '0' or line[15] > '9') return false;

        if (line[16] != ':') return false;

        if (line[17] < '0' or line[17] > '9') return false;
        if (line[18] < '0' or line[18] > '9') return false;

        if (line[19] != ',') return false;

        if (line[20] < '0' or line[20] > '9') return false;
        if (line[21] < '0' or line[21] > '9') return false;
        if (line[22] < '0' or line[22] > '9') return false;

        if (line[23] != ' ') return false;
        if (line[24] != '[') return false;

        return true;
    }
};
