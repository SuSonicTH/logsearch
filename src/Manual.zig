const std = @import("std");
const readme = @import("readme");

/// Pagers and markdown renderers to try, in order of preference.
/// Every candidate reads the manual from standard input.
const pagers = [_][]const []const u8{
    // mdcat renders markdown and uses less (or $PAGER) with -p.
    &.{ "mdcat", "-p", "-" },
    // mdless is mdcat invoked in paginating mode.
    &.{ "mdless", "-" },
    // glow actually renders markdown and can use its own pager.
    &.{ "glow", "-p", "-" },
    // bat only syntax-highlights markdown, but is fast, widely available
    // and has a built-in pager.
    &.{ "bat", "--paging=always", "--style=plain", "--language=markdown" },
    // Debian and Ubuntu install bat as batcat.
    &.{ "batcat", "--paging=always", "--style=plain", "--language=markdown" },
    // Plain pagers, no markdown rendering.
    &.{ "less", "-R" },
    &.{"more"},
};

/// Show the embedded README. If standard output is a terminal, try the
/// preferred pager/markdown renderer first. If none can be started, or the
/// output is redirected, print the manual directly to standard output.
pub fn show(io: std.Io) !void {
    if (stdoutIsTty(io)) {
        for (pagers) |argv| {
            if (try showWithPager(io, argv)) return;
        }
    }
    try print(io);
}

fn stdoutIsTty(io: std.Io) bool {
    return std.Io.File.stdout().isTty(io) catch false;
}

fn showWithPager(io: std.Io, argv: []const []const u8) !bool {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
    }) catch return false;
    defer child.kill(io);

    if (child.stdin) |stdin| {
        // The pager may be quit before it has read everything, so write
        // errors such as BrokenPipe are expected and not fatal.
        stdin.writeStreamingAll(io, readme.text) catch {};
        stdin.close(io);
        child.stdin = null;
    }

    _ = child.wait(io) catch {};
    return true;
}

fn print(io: std.Io) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.writeAll(readme.text);
    try writer.interface.flush();
}

test "embedded manual" {
    try std.testing.expect(readme.text.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, readme.text, "# LogSearch"));
}
