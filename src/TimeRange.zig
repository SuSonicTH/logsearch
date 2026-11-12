const std = @import("std");

/// A packed, sortable timestamp key: YYYYMMDDHHMMSSmmm.
pub const Key = u64;

/// A wall-clock time range parsed from `--start` and `--end`.
///
/// Bounds are inclusive. A partial datetime describes a whole period, so the
/// start uses the first moment of that period and the end uses the last.
pub const TimeRange = @This();

start: ?Key = null,
end: ?Key = null,

pub const ParseError = error{
    InvalidDateTime,
    StartAfterEnd,
};

const Precision = enum {
    month,
    day,
    hour,
    minute,
    second,
    millisecond,
};

const DateTime = struct {
    year: u16,
    month: u8,
    day: u8 = 1,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    millis: u16 = 0,
    precision: Precision,
};

pub fn init(start_value: ?[]const u8, end_value: ?[]const u8) ParseError!TimeRange {
    var result: TimeRange = .{};
    if (start_value) |value| result.start = try parseStart(value);
    if (end_value) |value| result.end = try parseEnd(value);
    if (result.start) |start| {
        if (result.end) |end| {
            if (start > end) return error.StartAfterEnd;
        }
    }
    return result;
}

pub fn parseStart(value: []const u8) ParseError!Key {
    return toKey(try parseDateTime(value));
}

pub fn parseEnd(value: []const u8) ParseError!Key {
    return upperKey(try parseDateTime(value));
}

pub fn isActive(self: TimeRange) bool {
    return self.start != null or self.end != null;
}

pub fn contains(self: TimeRange, key: Key) bool {
    if (self.start) |start| {
        if (key < start) return false;
    }
    if (self.end) |end| {
        if (key > end) return false;
    }
    return true;
}

/// Parse the timestamp text captured by the configured time pattern. Returns
/// null when the text is not a recognized date/time.
pub fn timestampKey(text: []const u8) ?Key {
    const date = parseDateTime(text) catch return null;
    return toKey(date);
}

/// Log files are commonly rotated to names ending in their date, such as
/// `app.log.2025-10-19`. When such a filename is completely outside the
/// requested range, the file can be skipped without opening it.
pub fn shouldSkipFile(self: TimeRange, file_name: []const u8) bool {
    if (!self.isActive()) return false;
    if (file_name.len < 10) return false;

    const suffix = file_name[file_name.len - 10 ..];
    const date = parseDateTime(suffix) catch return false;
    if (date.precision != .day) return false;

    const file_start = toKey(date);
    const file_end = upperKey(date);

    if (self.start) |start| {
        if (file_end < start) return true;
    }
    if (self.end) |end| {
        if (file_start > end) return true;
    }
    return false;
}

fn parseDateTime(value: []const u8) ParseError!DateTime {
    if (value.len < 7) return error.InvalidDateTime;
    if (value[4] != '-') return error.InvalidDateTime;

    const year = try parseDigits(value[0..4]);
    const month = try parseDigits(value[5..7]);
    if (year == 0 or month == 0 or month > 12) return error.InvalidDateTime;

    var result: DateTime = .{
        .year = year,
        .month = @intCast(month),
        .precision = .month,
    };

    if (value.len == 7) return result;

    if (value.len < 10 or value[7] != '-') return error.InvalidDateTime;
    const day = try parseDigits(value[8..10]);
    if (day == 0 or day > daysInMonth(year, @intCast(month))) return error.InvalidDateTime;
    result.day = @intCast(day);
    result.precision = .day;

    if (value.len == 10) return result;

    if (value.len < 13 or (value[10] != ' ' and value[10] != 'T')) return error.InvalidDateTime;
    const hour = try parseDigits(value[11..13]);
    if (hour > 23) return error.InvalidDateTime;
    result.hour = @intCast(hour);
    result.precision = .hour;

    if (value.len == 13) return result;

    if (value.len < 16 or value[13] != ':') return error.InvalidDateTime;
    const minute = try parseDigits(value[14..16]);
    if (minute > 59) return error.InvalidDateTime;
    result.minute = @intCast(minute);
    result.precision = .minute;

    if (value.len == 16) return result;

    if (value.len < 19 or value[16] != ':') return error.InvalidDateTime;
    const second = try parseDigits(value[17..19]);
    if (second > 59) return error.InvalidDateTime;
    result.second = @intCast(second);
    result.precision = .second;

    if (value.len == 19) return result;

    if (value.len != 23 or (value[19] != ',' and value[19] != '.')) return error.InvalidDateTime;
    result.millis = try parseDigits(value[20..23]);
    result.precision = .millisecond;

    return result;
}

fn parseDigits(value: []const u8) ParseError!u16 {
    var result: u16 = 0;
    for (value) |c| {
        if (c < '0' or c > '9') return error.InvalidDateTime;
        result = result * 10 + (c - '0');
    }
    return result;
}

fn toKey(date: DateTime) Key {
    var key: Key = date.year;
    key = key * 100 + @as(Key, date.month);
    key = key * 100 + @as(Key, date.day);
    key = key * 100 + @as(Key, date.hour);
    key = key * 100 + @as(Key, date.minute);
    key = key * 100 + @as(Key, date.second);
    key = key * 1000 + @as(Key, date.millis);
    return key;
}

fn upperKey(date: DateTime) Key {
    var result = date;
    switch (result.precision) {
        .month => {
            result.day = daysInMonth(result.year, result.month);
            result.hour = 23;
            result.minute = 59;
            result.second = 59;
            result.millis = 999;
        },
        .day => {
            result.hour = 23;
            result.minute = 59;
            result.second = 59;
            result.millis = 999;
        },
        .hour => {
            result.minute = 59;
            result.second = 59;
            result.millis = 999;
        },
        .minute => {
            result.second = 59;
            result.millis = 999;
        },
        .second => {
            result.millis = 999;
        },
        .millisecond => {},
    }
    return toKey(result);
}

fn isLeapYear(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
}

fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => unreachable,
    };
}

test "parse start and end periods" {
    try std.testing.expectEqual(@as(Key, 20251001000000000), try parseStart("2025-10"));
    try std.testing.expectEqual(@as(Key, 20251031235959999), try parseEnd("2025-10"));

    try std.testing.expectEqual(@as(Key, 20251008000000000), try parseStart("2025-10-08"));
    try std.testing.expectEqual(@as(Key, 20251008235959999), try parseEnd("2025-10-08"));

    try std.testing.expectEqual(@as(Key, 20251008090000000), try parseStart("2025-10-08 09"));
    try std.testing.expectEqual(@as(Key, 20251008095959999), try parseEnd("2025-10-08 09"));

    try std.testing.expectEqual(@as(Key, 20251008093000000), try parseStart("2025-10-08 09:30"));
    try std.testing.expectEqual(@as(Key, 20251008093059999), try parseEnd("2025-10-08 09:30"));

    try std.testing.expectEqual(@as(Key, 20251008093001000), try parseStart("2025-10-08 09:30:01"));
    try std.testing.expectEqual(@as(Key, 20251008093001999), try parseEnd("2025-10-08 09:30:01"));

    try std.testing.expectEqual(@as(Key, 20251008093001002), try parseStart("2025-10-08 09:30:01,002"));
    try std.testing.expectEqual(@as(Key, 20251008093001002), try parseEnd("2025-10-08 09:30:01,002"));
}

test "alternate separators" {
    try std.testing.expectEqual(@as(Key, 20251008093001002), try parseStart("2025-10-08T09:30:01.002"));
}

test "month and leap year ends" {
    try std.testing.expectEqual(@as(Key, 20240229235959999), try parseEnd("2024-02"));
    try std.testing.expectEqual(@as(Key, 20250228235959999), try parseEnd("2025-02"));
    try std.testing.expectEqual(@as(Key, 20250430235959999), try parseEnd("2025-04"));
}

test "invalid datetimes" {
    try std.testing.expectError(error.InvalidDateTime, parseStart("2025-13"));
    try std.testing.expectError(error.InvalidDateTime, parseStart("2025-00"));
    try std.testing.expectError(error.InvalidDateTime, parseStart("2025-02-30"));
    try std.testing.expectError(error.InvalidDateTime, parseStart("2025-02-29"));
    try std.testing.expectError(error.InvalidDateTime, parseStart("2025-04-31"));
    try std.testing.expectError(error.InvalidDateTime, parseStart("2025-1"));
    try std.testing.expectError(error.InvalidDateTime, parseStart("25-01-01"));
    try std.testing.expectError(error.InvalidDateTime, parseStart("2025-01-01 24"));
    try std.testing.expectError(error.InvalidDateTime, parseStart("2025-01-01 12:60"));
    try std.testing.expectError(error.InvalidDateTime, parseStart("2025-01-01 12:00:60"));
    try std.testing.expectError(error.InvalidDateTime, parseStart("2025-01-01 12:00:00,0000"));
}

test "start after end" {
    try std.testing.expectError(error.StartAfterEnd, init("2025-10-20", "2025-10-19"));
}

test "timestamp keys" {
    try std.testing.expectEqual(@as(?Key, 20251008093001002), timestampKey("2025-10-08 09:30:01,002"));
    try std.testing.expectEqual(@as(?Key, 20251008093001002), timestampKey("2025-10-08T09:30:01.002"));
    try std.testing.expectEqual(@as(?Key, null), timestampKey("not a timestamp"));
}

test "file skip by date suffix" {
    const range = try init("2025-10-19", "2025-10-19");
    try std.testing.expect(!range.shouldSkipFile("BlackMed.log.2025-10-19"));
    try std.testing.expect(range.shouldSkipFile("BlackMed.log.2025-10-18"));
    try std.testing.expect(range.shouldSkipFile("BlackMed.log.2025-10-20"));
    try std.testing.expect(!range.shouldSkipFile("BlackMed.log"));
}

test "file skip with open bounds" {
    const start_only = try init("2025-10-19", null);
    try std.testing.expect(start_only.shouldSkipFile("BlackMed.log.2025-10-18"));
    try std.testing.expect(!start_only.shouldSkipFile("BlackMed.log.2025-10-19"));
    try std.testing.expect(!start_only.shouldSkipFile("BlackMed.log.2025-10-20"));

    const end_only = try init(null, "2025-10-19");
    try std.testing.expect(!end_only.shouldSkipFile("BlackMed.log.2025-10-18"));
    try std.testing.expect(!end_only.shouldSkipFile("BlackMed.log.2025-10-19"));
    try std.testing.expect(end_only.shouldSkipFile("BlackMed.log.2025-10-20"));
}
