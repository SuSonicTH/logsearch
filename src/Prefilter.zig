const std = @import("std");

/// A cheap necessary-condition check for a regular expression.
///
/// For a substring search, a regex can only match if a literal that is
/// required by the pattern occurs in the haystack. The analyzer below walks
/// the regex and extracts such a literal (or a small alternation of literals)
/// so that `memchr`/`memmem` can reject most haystacks before the much slower
/// regex engine is invoked.
///
/// When the pattern consists entirely of literals and small character-class
/// expansions, the check is also *sufficient*: finding one of the extracted
/// strings means the regex matches, so the regex engine can be skipped
/// entirely.
///
/// The analysis is conservative. Anything that cannot be reasoned about
/// safely yields `.none`, which means "always run the regex".
pub const Prefilter = struct {
    kind: Kind = .none,
    /// True when `matches()` returning true guarantees that the regex matches.
    /// Constructs such as anchors, wildcards, large quantifiers, and negated
    /// classes make the check necessary but not sufficient.
    exact: bool = false,

    pub const Kind = union(enum) {
        none,
        literal: []const u8,
        any_of: []const []const u8,
    };

    pub fn analyze(allocator: std.mem.Allocator, pattern: []const u8) !Prefilter {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();

        var parser: Parser = .{
            .pattern = pattern,
            .allocator = arena_state.allocator(),
        };
        const req = parser.parseAlternation() catch |err| switch (err) {
            error.Unsupported => return .{},
            else => return err,
        };
        if (parser.pos != pattern.len) return .{};
        if (req.alts.len == 0) return .{};

        // A necessary-only prefilter with an empty alternative matches every
        // haystack and therefore costs time without filtering anything.
        if (!req.exact) {
            for (req.alts) |literal| {
                if (literal.len == 0) return .{};
            }
        }

        return toPrefilter(allocator, req);
    }

    pub fn deinit(self: Prefilter, allocator: std.mem.Allocator) void {
        switch (self.kind) {
            .none => {},
            .literal => |literal| allocator.free(literal),
            .any_of => |literals| {
                for (literals) |literal| allocator.free(literal);
                allocator.free(literals);
            },
        }
    }

    pub inline fn matches(self: Prefilter, haystack: []const u8) bool {
        switch (self.kind) {
            .none => return true,
            .literal => |literal| return std.mem.indexOf(u8, haystack, literal) != null,
            .any_of => |literals| {
                for (literals) |literal| {
                    if (std.mem.indexOf(u8, haystack, literal) != null) return true;
                }
                return false;
            },
        }
    }
};

const max_alts: usize = 32;
const max_exact_len: usize = 2048;
const max_depth: usize = 64;

const ParseError = std.mem.Allocator.Error || error{Unsupported};

const Req = struct {
    /// Empty means "no useful prefilter" (match everything / run the regex).
    /// Otherwise the regex can only match if at least one of these literals
    /// occurs in the haystack.
    alts: []const []const u8 = &.{},
    /// True when `alts` are complete match strings, so finding one of them is
    /// sufficient for the regex to match.
    exact: bool = false,
};

const Atom = struct {
    req: Req = .{},
    /// Set for an unquantified literal character, allowing runs of adjacent
    /// literals to be joined into a single longer prefilter.
    single_literal: ?u8 = null,
    anchor: bool = false,
};

const Quantifier = struct {
    min: usize,
    max: ?usize, // null = unbounded
};

const Parser = struct {
    pattern: []const u8,
    pos: usize = 0,
    allocator: std.mem.Allocator,
    depth: usize = 0,

    fn parseAlternation(self: *Parser) ParseError!Req {
        var branches: std.ArrayList(Req) = .empty;
        try branches.append(self.allocator, try self.parseSequence());

        while (self.pos < self.pattern.len and self.pattern[self.pos] == '|') {
            self.pos += 1;
            try branches.append(self.allocator, try self.parseSequence());
        }

        if (branches.items.len == 1) return branches.items[0];
        return self.combineAlternation(branches.items);
    }

    fn parseSequence(self: *Parser) ParseError!Req {
        var run: std.ArrayList(u8) = .empty;
        var best: Req = .{};
        var has_anchor = false;

        var exact_possible = true;
        var exact_alts: []const []const u8 = try self.emptyAlts();

        while (self.pos < self.pattern.len) {
            const c = self.pattern[self.pos];
            if (c == '|' or c == ')') break;

            const atom = try self.parseAtom();

            if (atom.anchor) {
                has_anchor = true;
                continue;
            }

            if (atom.single_literal) |ch| {
                try run.append(self.allocator, ch);
            } else {
                try self.finalizeRun(&run, &best);
                best = better(best, atom.req);
            }

            if (exact_possible) {
                if (atom.req.exact and atom.req.alts.len > 0) {
                    if (try self.crossExact(exact_alts, atom.req.alts)) |crossed| {
                        exact_alts = crossed;
                    } else {
                        exact_possible = false;
                    }
                } else {
                    exact_possible = false;
                }
            }
        }

        try self.finalizeRun(&run, &best);

        if (exact_possible) {
            return .{ .alts = exact_alts, .exact = !has_anchor };
        }

        // The accumulated requirement is only a necessary condition for the
        // whole sequence, never a sufficient one.
        if (best.alts.len == 0) return .{};
        return .{ .alts = best.alts, .exact = false };
    }

    fn parseAtom(self: *Parser) ParseError!Atom {
        const c = self.pattern[self.pos];
        switch (c) {
            '^', '$' => {
                self.pos += 1;
                return .{ .anchor = true };
            },
            '\\' => {
                const atom = try self.parseEscape();
                if (atom.anchor) return atom;
                return self.quantify(atom);
            },
            '.' => {
                self.pos += 1;
                return self.quantify(.{});
            },
            '[' => {
                const req = try self.parseClass();
                return self.quantify(.{ .req = req });
            },
            '(' => {
                const req = try self.parseGroup();
                return self.quantify(.{ .req = req });
            },
            '*', '+', '?', '{', ']', '}' => return error.Unsupported,
            else => {
                self.pos += 1;
                return self.quantify(.{
                    .req = try self.singleLiteralReq(c),
                    .single_literal = c,
                });
            },
        }
    }

    fn parseGroup(self: *Parser) ParseError!Req {
        // self.pos is at '('
        self.pos += 1;
        if (self.depth >= max_depth) return error.Unsupported;
        self.depth += 1;
        defer self.depth -= 1;

        // mvzr has no non-capturing groups, flags, or lookarounds. If it looks
        // like one of those, fall back rather than guessing.
        if (self.pos < self.pattern.len and self.pattern[self.pos] == '?') {
            return error.Unsupported;
        }

        const inner = try self.parseAlternation();
        if (self.pos >= self.pattern.len or self.pattern[self.pos] != ')') {
            return error.Unsupported;
        }
        self.pos += 1;
        return inner;
    }

    fn parseEscape(self: *Parser) ParseError!Atom {
        // self.pos is at '\\'
        self.pos += 1;
        if (self.pos >= self.pattern.len) return error.Unsupported;
        const escaped = self.pattern[self.pos];
        self.pos += 1;

        return switch (escaped) {
            'd' => .{ .req = try self.byteSetReq("0123456789") },
            // \D, \W and \w are too broad to enumerate cheaply.
            'D', 'w', 'W' => .{},
            's' => .{ .req = try self.byteSetReq("\t\n\r\x0b\x0c ") },
            'S' => .{},
            'b', 'B' => .{ .anchor = true },
            'r' => .{ .req = try self.singleLiteralReq('\r'), .single_literal = '\r' },
            'n' => .{ .req = try self.singleLiteralReq('\n'), .single_literal = '\n' },
            't' => .{ .req = try self.singleLiteralReq('\t'), .single_literal = '\t' },
            'x' => blk: {
                if (self.pos + 2 > self.pattern.len) return error.Unsupported;
                const value = std.fmt.parseInt(u8, self.pattern[self.pos .. self.pos + 2], 16) catch
                    return error.Unsupported;
                self.pos += 2;
                break :blk .{
                    .req = try self.singleLiteralReq(value),
                    .single_literal = value,
                };
            },
            // mvzr treats every other escape as a literal character.
            else => .{
                .req = try self.singleLiteralReq(escaped),
                .single_literal = escaped,
            },
        };
    }

    fn parseClass(self: *Parser) ParseError!Req {
        // self.pos is at '['
        self.pos += 1;

        var negated = false;
        if (self.pos < self.pattern.len and self.pattern[self.pos] == '^') {
            negated = true;
            self.pos += 1;
        }

        var seen: [256]bool = @splat(false);
        var count: usize = 0;
        var supported = true;

        while (self.pos < self.pattern.len and self.pattern[self.pos] != ']') {
            const first = try self.parseClassItem();

            if (self.pos < self.pattern.len and self.pattern[self.pos] == '-' and
                self.pos + 1 < self.pattern.len and self.pattern[self.pos + 1] != ']')
            {
                self.pos += 1;
                const last = try self.parseClassItem();
                if (first == null or last == null or first.? > last.?) {
                    supported = false;
                } else {
                    var b: usize = first.?;
                    while (b <= last.?) : (b += 1) addClassByte(&seen, &count, @intCast(b));
                }
            } else if (first) |b| {
                addClassByte(&seen, &count, b);
            } else {
                supported = false;
            }
        }

        if (self.pos >= self.pattern.len or self.pattern[self.pos] != ']') {
            return error.Unsupported;
        }
        self.pos += 1;

        if (negated or !supported or count == 0 or count > max_alts) return .{};

        const alts = try self.allocator.alloc([]const u8, count);
        var index: usize = 0;
        for (seen, 0..) |present, b| {
            if (!present) continue;
            const literal = try self.allocator.alloc(u8, 1);
            literal[0] = @intCast(b);
            alts[index] = literal;
            index += 1;
        }
        return .{ .alts = alts, .exact = true };
    }

    /// Returns a single literal byte, or null for an item that cannot be
    /// expanded cheaply (e.g. `\d` inside a class). The position is advanced
    /// in both cases.
    fn parseClassItem(self: *Parser) ParseError!?u8 {
        if (self.pos >= self.pattern.len) return error.Unsupported;
        const c = self.pattern[self.pos];
        self.pos += 1;
        if (c != '\\') return c;

        if (self.pos >= self.pattern.len) return error.Unsupported;
        const escaped = self.pattern[self.pos];
        self.pos += 1;

        return switch (escaped) {
            'd', 'D', 'w', 'W', 's', 'S' => null,
            'r' => '\r',
            'n' => '\n',
            't' => '\t',
            'x' => blk: {
                if (self.pos + 2 > self.pattern.len) return error.Unsupported;
                const value = std.fmt.parseInt(u8, self.pattern[self.pos .. self.pos + 2], 16) catch
                    return error.Unsupported;
                self.pos += 2;
                break :blk value;
            },
            else => escaped,
        };
    }

    fn quantify(self: *Parser, atom: Atom) ParseError!Atom {
        const quantifier = try self.parseQuantifier() orelse return atom;

        if (quantifier.min == 1 and quantifier.max != null and quantifier.max.? == 1) {
            return atom;
        }

        if (quantifier.max != null and quantifier.max.? == 0) {
            return .{ .req = try self.emptyReq() };
        }

        if (quantifier.min == 0 and quantifier.max != null and quantifier.max.? == 1) {
            // Optional: exact when the atom itself was exact (0 or 1 copies).
            if (atom.req.exact and atom.req.alts.len > 0) {
                return .{ .req = try self.optionalReq(atom.req) };
            }
            return .{};
        }

        if (quantifier.min == 0) {
            // `*`, `{0,n}` with n > 1: the atom may be absent, so it cannot
            // contribute a required literal.
            return .{};
        }

        // min >= 1: at least one copy is required. This is necessary but not
        // sufficient because more copies may also occur.
        if (atom.req.alts.len > 0) {
            return .{ .req = .{ .alts = atom.req.alts, .exact = false } };
        }
        return .{};
    }

    fn parseQuantifier(self: *Parser) ParseError!?Quantifier {
        if (self.pos >= self.pattern.len) return null;

        return switch (self.pattern[self.pos]) {
            '?' => blk: {
                self.pos += 1;
                self.consumeModifier();
                break :blk .{ .min = 0, .max = 1 };
            },
            '*' => blk: {
                self.pos += 1;
                self.consumeModifier();
                break :blk .{ .min = 0, .max = null };
            },
            '+' => blk: {
                self.pos += 1;
                self.consumeModifier();
                break :blk .{ .min = 1, .max = null };
            },
            '{' => try self.parseBraceQuantifier(),
            else => null,
        };
    }

    fn parseBraceQuantifier(self: *Parser) ParseError!?Quantifier {
        // self.pos is at '{'
        self.pos += 1;
        const start = self.pos;
        while (self.pos < self.pattern.len and self.pattern[self.pos] != '}') : (self.pos += 1) {
            const c = self.pattern[self.pos];
            if (!std.ascii.isDigit(c) and c != ',') return error.Unsupported;
        }
        if (self.pos >= self.pattern.len) return error.Unsupported;

        const content = self.pattern[start..self.pos];
        self.pos += 1;
        self.consumeModifier();

        return parseQuantifierContent(content) orelse error.Unsupported;
    }

    fn consumeModifier(self: *Parser) void {
        if (self.pos < self.pattern.len) {
            switch (self.pattern[self.pos]) {
                '?', '+' => self.pos += 1,
                else => {},
            }
        }
    }

    fn parseQuantifierContent(content: []const u8) ?Quantifier {
        if (content.len == 0) return null;

        if (std.mem.indexOfScalar(u8, content, ',')) |comma| {
            const left = content[0..comma];
            const right = content[comma + 1 ..];
            if (std.mem.indexOfScalar(u8, right, ',') != null) return null;

            const min = if (left.len == 0) 0 else parseCount(left) orelse return null;
            const max = if (right.len == 0) null else parseCount(right) orelse return null;
            if (max != null and min > max.?) return null;
            return .{ .min = min, .max = max };
        }

        const count = parseCount(content) orelse return null;
        return .{ .min = count, .max = count };
    }

    fn parseCount(text: []const u8) ?usize {
        if (text.len == 0 or text.len > 3) return null;
        const value = std.fmt.parseInt(usize, text, 10) catch return null;
        if (value > 255) return null;
        return value;
    }

    fn combineAlternation(self: *Parser, branches: []const Req) ParseError!Req {
        var total: usize = 0;
        var all_exact = true;
        for (branches) |branch| {
            if (branch.alts.len == 0) return .{};
            total += branch.alts.len;
            if (!branch.exact) all_exact = false;
        }
        if (total > max_alts) return .{};

        const alts = try self.allocator.alloc([]const u8, total);
        var index: usize = 0;
        for (branches) |branch| {
            for (branch.alts) |literal| {
                alts[index] = literal;
                index += 1;
            }
        }
        return .{ .alts = alts, .exact = all_exact };
    }

    fn crossExact(
        self: *Parser,
        left: []const []const u8,
        right: []const []const u8,
    ) ParseError!?[]const []const u8 {
        if (left.len == 0 or right.len == 0) return null;
        if (right.len > max_alts or left.len > max_alts / right.len) return null;

        const total = left.len * right.len;
        if (total > max_alts) return null;

        for (left) |a| {
            for (right) |b| {
                if (a.len + b.len > max_exact_len) return null;
            }
        }

        const alts = try self.allocator.alloc([]const u8, total);
        var index: usize = 0;
        for (left) |a| {
            for (right) |b| {
                alts[index] = try std.mem.concat(self.allocator, u8, &.{ a, b });
                index += 1;
            }
        }
        return alts;
    }

    fn finalizeRun(
        self: *Parser,
        run: *std.ArrayList(u8),
        best: *Req,
    ) ParseError!void {
        if (run.items.len == 0) return;
        const literal = try self.allocator.dupe(u8, run.items);
        run.clearRetainingCapacity();

        const alts = try self.allocator.alloc([]const u8, 1);
        alts[0] = literal;
        best.* = better(best.*, .{ .alts = alts, .exact = true });
    }

    fn emptyReq(self: *Parser) ParseError!Req {
        return .{ .alts = try self.emptyAlts(), .exact = true };
    }

    fn emptyAlts(self: *Parser) ParseError![]const []const u8 {
        const alts = try self.allocator.alloc([]const u8, 1);
        alts[0] = "";
        return alts;
    }

    fn optionalReq(self: *Parser, req: Req) ParseError!Req {
        const alts = try self.allocator.alloc([]const u8, req.alts.len + 1);
        alts[0] = "";
        @memcpy(alts[1..], req.alts);
        return .{ .alts = alts, .exact = true };
    }

    fn singleLiteralReq(self: *Parser, ch: u8) ParseError!Req {
        const literal = try self.allocator.alloc(u8, 1);
        literal[0] = ch;
        const alts = try self.allocator.alloc([]const u8, 1);
        alts[0] = literal;
        return .{ .alts = alts, .exact = true };
    }

    fn byteSetReq(self: *Parser, bytes: []const u8) ParseError!Req {
        const alts = try self.allocator.alloc([]const u8, bytes.len);
        for (bytes, 0..) |byte, index| {
            const literal = try self.allocator.alloc(u8, 1);
            literal[0] = byte;
            alts[index] = literal;
        }
        return .{ .alts = alts, .exact = true };
    }
};

fn addClassByte(seen: *[256]bool, count: *usize, byte: u8) void {
    if (seen[byte]) return;
    seen[byte] = true;
    count.* += 1;
}

fn better(a: Req, b: Req) Req {
    if (a.alts.len == 0) return b;
    if (b.alts.len == 0) return a;

    const a_len = minLen(a);
    const b_len = minLen(b);
    if (b_len > a_len) return b;
    if (a_len > b_len) return a;
    return if (b.alts.len < a.alts.len) b else a;
}

fn minLen(req: Req) usize {
    var result: usize = std.math.maxInt(usize);
    for (req.alts) |literal| result = @min(result, literal.len);
    return if (result == std.math.maxInt(usize)) 0 else result;
}

fn toPrefilter(allocator: std.mem.Allocator, req: Req) !Prefilter {
    if (req.alts.len == 1) {
        return .{
            .kind = .{ .literal = try allocator.dupe(u8, req.alts[0]) },
            .exact = req.exact,
        };
    }

    const literals = try allocator.alloc([]const u8, req.alts.len);
    var initialized: usize = 0;
    errdefer {
        for (literals[0..initialized]) |literal| allocator.free(literal);
        allocator.free(literals);
    }
    for (req.alts, 0..) |literal, index| {
        literals[index] = try allocator.dupe(u8, literal);
        initialized = index + 1;
    }
    return .{ .kind = .{ .any_of = literals }, .exact = req.exact };
}

test "plain literal is exact" {
    const allocator = std.testing.allocator;
    var filter = try Prefilter.analyze(allocator, "timeout while waiting");
    defer filter.deinit(allocator);
    try std.testing.expect(filter.exact);
    try std.testing.expect(filter.matches("read timeout while waiting for db"));
    try std.testing.expect(!filter.matches("connection refused"));
}

test "escaped literal is exact" {
    const allocator = std.testing.allocator;
    var filter = try Prefilter.analyze(allocator, "com\\.example\\.");
    defer filter.deinit(allocator);
    try std.testing.expect(filter.exact);
    try std.testing.expect(filter.matches("at com.example.Db.query"));
    try std.testing.expect(!filter.matches("at comXexampleYDb"));
}

test "anchored literal is necessary only" {
    const allocator = std.testing.allocator;
    var filter = try Prefilter.analyze(allocator, "^ERROR:.*");
    defer filter.deinit(allocator);
    try std.testing.expect(std.meta.activeTag(filter.kind) == .literal);
    try std.testing.expect(!filter.exact);
    try std.testing.expect(filter.matches("ERROR: failed"));
    try std.testing.expect(!filter.matches("failed"));

    var anchored = try Prefilter.analyze(allocator, "^ERROR:$");
    defer anchored.deinit(allocator);
    try std.testing.expect(!anchored.exact);
    try std.testing.expect(anchored.matches("ERROR:"));
}

test "alternation" {
    const allocator = std.testing.allocator;
    var filter = try Prefilter.analyze(allocator, "timeout|refused|Exception");
    defer filter.deinit(allocator);
    try std.testing.expect(filter.exact);
    try std.testing.expect(filter.matches("connection refused"));
    try std.testing.expect(filter.matches("java.lang.Exception: x"));
    try std.testing.expect(!filter.matches("all good"));
}

test "escaped pipe is a literal" {
    const allocator = std.testing.allocator;
    var filter = try Prefilter.analyze(allocator, "a\\|b");
    defer filter.deinit(allocator);
    try std.testing.expect(std.meta.activeTag(filter.kind) == .literal);
    try std.testing.expect(filter.exact);
    try std.testing.expect(filter.matches("x a|b y"));
    try std.testing.expect(!filter.matches("x a y"));
}

test "small character class is expanded" {
    const allocator = std.testing.allocator;
    var filter = try Prefilter.analyze(allocator, "[Ee]rror");
    defer filter.deinit(allocator);
    try std.testing.expect(filter.exact);
    try std.testing.expect(filter.matches("java.lang.Error: x"));
    try std.testing.expect(filter.matches("java.lang.error: x"));
    try std.testing.expect(!filter.matches("java.lang.ERROR: x"));
}

test "literal prefix before class" {
    const allocator = std.testing.allocator;
    var filter = try Prefilter.analyze(allocator, "com\\.example\\.[A-Za-z]+");
    defer filter.deinit(allocator);
    try std.testing.expect(!filter.exact);
    try std.testing.expect(filter.matches("at com.example.Db.query"));
    try std.testing.expect(!filter.matches("at org.example.Db.query"));
}

test "group alternation and suffix" {
    const allocator = std.testing.allocator;
    var filter = try Prefilter.analyze(allocator, "(timeout|refused):");
    defer filter.deinit(allocator);
    try std.testing.expect(filter.exact);
    try std.testing.expect(filter.matches("timeout: db"));
    try std.testing.expect(filter.matches("refused: db"));
    try std.testing.expect(!filter.matches("timeout db"));
}

test "optional groups and quantifiers" {
    const allocator = std.testing.allocator;

    var optional_group = try Prefilter.analyze(allocator, "(foo|bar)?baz");
    defer optional_group.deinit(allocator);
    try std.testing.expect(optional_group.exact);
    try std.testing.expect(optional_group.matches("baz"));
    try std.testing.expect(optional_group.matches("foobaz"));
    try std.testing.expect(optional_group.matches("barbaz"));

    var optional_literal = try Prefilter.analyze(allocator, "colou?r");
    defer optional_literal.deinit(allocator);
    try std.testing.expect(optional_literal.exact);
    try std.testing.expect(optional_literal.matches("color"));
    try std.testing.expect(optional_literal.matches("colour"));

    var empty_branch = try Prefilter.analyze(allocator, "a(b|)c");
    defer empty_branch.deinit(allocator);
    try std.testing.expect(empty_branch.exact);
    try std.testing.expect(empty_branch.matches("abc"));
    try std.testing.expect(empty_branch.matches("ac"));
}

test "wildcards and unbounded quantifiers are necessary only" {
    const allocator = std.testing.allocator;

    var wildcard = try Prefilter.analyze(allocator, "foo.*bar");
    defer wildcard.deinit(allocator);
    try std.testing.expect(!wildcard.exact);
    try std.testing.expect(wildcard.matches("foo x bar"));
    // Only one of the two required literals is kept; both are necessary.
    try std.testing.expect(!wildcard.matches("xxbarxx"));
    try std.testing.expect(!wildcard.matches("nothing"));

    var digits = try Prefilter.analyze(allocator, "ERROR[0-9]+");
    defer digits.deinit(allocator);
    try std.testing.expect(!digits.exact);
    try std.testing.expect(digits.matches("ERROR42"));
    try std.testing.expect(!digits.matches("WARN42"));

    var negated = try Prefilter.analyze(allocator, "[^ ]+ERROR");
    defer negated.deinit(allocator);
    try std.testing.expect(!negated.exact);
    try std.testing.expect(negated.matches("xxERROR"));
    try std.testing.expect(!negated.matches("xx"));
}

test "unsupported patterns fall back" {
    const allocator = std.testing.allocator;

    var wide_class = try Prefilter.analyze(allocator, "[A-Za-z]+");
    defer wide_class.deinit(allocator);
    try std.testing.expect(std.meta.activeTag(wide_class.kind) == .none);

    var unterminated = try Prefilter.analyze(allocator, "[Ee");
    defer unterminated.deinit(allocator);
    try std.testing.expect(std.meta.activeTag(unterminated.kind) == .none);

    var lookaround = try Prefilter.analyze(allocator, "(?=foo)bar");
    defer lookaround.deinit(allocator);
    try std.testing.expect(std.meta.activeTag(lookaround.kind) == .none);
}

test "prefilter is sound with respect to mvzr" {
    const mvzr = @import("mvzr");
    const allocator = std.testing.allocator;

    const patterns = [_][]const u8{
        "literal",
        "a\\|b",
        "[Ee]rror",
        "[Tt]rue|[Ff]alse",
        "(timeout|refused):",
        "(foo|bar)?baz",
        "colou?r",
        "a(b|)c",
        "foo|",
        "foo.*bar",
        "ERROR[0-9]+",
        "ERROR[0-9]{2,4}",
        "[^ ]+ERROR",
        "\\d{3} ERROR",
        "^[Ee]rror$",
        "\\bword\\b",
        "com\\.example\\.[A-Za-z]+",
        "x(y|z)+w",
        "\\x41BC",
        "[0-9A-Fa-f]+",
        "a{2,3}b",
        "a{0,2}b",
        "a{2}b",
        "a{,2}b",
        "a{2,}b",
    };

    const haystacks = [_][]const u8{
        "",
        "literal",
        "xliteralx",
        "a|b",
        "Error: failed",
        "error: failed",
        "ERROR: failed",
        "True",
        "false",
        "timeout: db",
        "refused: db",
        "timeout db",
        "baz",
        "foobaz",
        "barbaz",
        "color",
        "colour",
        "abc",
        "ac",
        "foo",
        "nothing",
        "foo x bar",
        "xxbarxx",
        "ERROR42",
        "ERROR1234",
        "xxERROR",
        "123 ERROR",
        "word here",
        "swordfish",
        "com.example.Db",
        "xyzzy",
        "ABC",
        "aab",
        "aaab",
        "ab",
        "aabb",
    };

    for (patterns) |pattern| {
        const regex = mvzr.compile(pattern) orelse continue;
        var filter = try Prefilter.analyze(allocator, pattern);
        defer filter.deinit(allocator);

        for (haystacks) |haystack| {
            const regex_matches = regex.isMatch(haystack);
            const prefilter_matches = filter.matches(haystack);

            if (!prefilter_matches) {
                try std.testing.expect(!regex_matches);
            }
            if (filter.exact) {
                try std.testing.expectEqual(regex_matches, prefilter_matches);
            }
        }
    }
}
