//! Debian suite resolution and security repository URLs.
const std = @import("std");

pub const Info = struct {
    suite: []const u8,
    daily: bool = false,
    number: u8,
};

pub fn backportsSuite(a: std.mem.Allocator, info: Info) ![]const u8 {
    // Retired backports live in a different archive; testing/sid do not have
    // a published backports suite. Do not silently install the stable kernel.
    if (info.daily or info.number < 12 or info.number > 13) return error.UnsupportedBackports;
    return std.fmt.allocPrint(a, "{s}-backports", .{info.suite});
}

pub fn resolve(value: []const u8) !Info {
    const v = std.mem.trim(u8, value, " \t\r\n");
    if (eqlIgnoreCase(v, "11") or eqlIgnoreCase(v, "bullseye") or eqlIgnoreCase(v, "oldoldstable")) return .{ .suite = "bullseye", .number = 11 };
    if (eqlIgnoreCase(v, "12") or eqlIgnoreCase(v, "bookworm") or eqlIgnoreCase(v, "oldstable")) return .{ .suite = "bookworm", .number = 12 };
    if (eqlIgnoreCase(v, "13") or eqlIgnoreCase(v, "trixie")) return .{ .suite = "trixie", .number = 13 };
    if (eqlIgnoreCase(v, "14") or eqlIgnoreCase(v, "forky") or eqlIgnoreCase(v, "testing")) return .{ .suite = "forky", .daily = true, .number = 14 };
    if (eqlIgnoreCase(v, "sid") or eqlIgnoreCase(v, "unstable")) return .{ .suite = "sid", .daily = true, .number = 99 };
    if (eqlIgnoreCase(v, "10") or eqlIgnoreCase(v, "buster")) return error.UnsupportedRelease;
    return error.UnsupportedRelease;
}

pub fn stableAlias(value: []const u8) bool {
    const v = std.mem.trim(u8, value, " \t\r\n");
    return v.len == 0 or eqlIgnoreCase(v, "stable");
}

pub fn parseStable(text: []const u8) ?Info {
    var code: []const u8 = "";
    var number: u8 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t\r");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t\r");
        if (eqlIgnoreCase(key, "Codename")) {
            code = value;
        } else if (eqlIgnoreCase(key, "Version")) {
            const end = std.mem.indexOfScalar(u8, value, '.') orelse value.len;
            number = std.fmt.parseInt(u8, value[0..end], 10) catch 0;
        }
    }
    if (!validCodename(code)) return null;
    const known = major(code);
    if (known != 0) number = known;
    if (number == 0) return null;
    return .{ .suite = code, .number = number };
}

pub fn validCodename(code: []const u8) bool {
    if (code.len < 3 or code.len > 16 or eqlIgnoreCase(code, "sid") or eqlIgnoreCase(code, "stable") or eqlIgnoreCase(code, "testing")) return false;
    for (code) |c| if (c < 'a' or c > 'z') return false;
    return true;
}

pub fn display(suite: []const u8) []const u8 {
    if (std.mem.eql(u8, suite, "bullseye")) return "11";
    if (std.mem.eql(u8, suite, "bookworm")) return "12";
    if (std.mem.eql(u8, suite, "trixie")) return "13";
    if (std.mem.eql(u8, suite, "forky")) return "14";
    return suite;
}

pub fn major(suite: []const u8) u8 {
    if (std.mem.eql(u8, suite, "bullseye")) return 11;
    if (std.mem.eql(u8, suite, "bookworm")) return 12;
    if (std.mem.eql(u8, suite, "trixie")) return 13;
    if (std.mem.eql(u8, suite, "forky")) return 14;
    if (std.mem.eql(u8, suite, "sid")) return 99;
    return 0;
}

pub fn securitySuite(arena: std.mem.Allocator, suite: []const u8) ![]const u8 {
    if (std.mem.eql(u8, suite, "buster")) return "buster/updates";
    return std.fmt.allocPrint(arena, "{s}-security", .{suite});
}

pub fn securityRepo(arena: std.mem.Allocator, protocol: []const u8, host: []const u8, dir: []const u8, suite: []const u8, daily: bool) !?[]const u8 {
    if (daily or std.mem.eql(u8, suite, "sid")) return null;
    const repo_host = if (std.mem.eql(u8, host, "ftp.debian.org")) "deb.debian.org" else host;
    const trimmed = if (std.mem.endsWith(u8, dir, "/")) dir[0 .. dir.len - 1] else dir;
    return try std.fmt.allocPrint(arena, "{s}://{s}{s}-security", .{ protocol, repo_host, trimmed });
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

test "resolve fixed Debian suites and aliases" {
    const Case = struct { input: []const u8, suite: []const u8, daily: bool, number: u8 };
    const cases = [_]Case{
        .{ .input = "11", .suite = "bullseye", .daily = false, .number = 11 },
        .{ .input = "OLDOLDSTABLE", .suite = "bullseye", .daily = false, .number = 11 },
        .{ .input = "12", .suite = "bookworm", .daily = false, .number = 12 },
        .{ .input = "oldstable", .suite = "bookworm", .daily = false, .number = 12 },
        .{ .input = "13", .suite = "trixie", .daily = false, .number = 13 },
        .{ .input = "testing", .suite = "forky", .daily = true, .number = 14 },
        .{ .input = "unstable", .suite = "sid", .daily = true, .number = 99 },
    };
    for (cases) |c| {
        const got = try resolve(c.input);
        try std.testing.expectEqualStrings(c.suite, got.suite);
        try std.testing.expectEqual(c.daily, got.daily);
        try std.testing.expectEqual(c.number, got.number);
    }
    try std.testing.expectError(error.UnsupportedRelease, resolve("10"));
    try std.testing.expectError(error.UnsupportedRelease, resolve("unknown"));
}

test "stable aliases and Release parsing" {
    try std.testing.expect(stableAlias(""));
    try std.testing.expect(stableAlias(" Stable \n"));
    try std.testing.expect(!stableAlias("trixie"));
    const known_without_version = parseStable("Codename: trixie\n").?;
    try std.testing.expectEqual(@as(u8, 13), known_without_version.number);
    const known = parseStable("Origin: Debian\nCodename: trixie\nVersion: 13.7\n").?;
    const unknown_no_version = parseStable("Codename: duke\n");
    try std.testing.expect(unknown_no_version == null);
    try std.testing.expect(parseStable("Version: 13.1\n") == null);
    try std.testing.expect(parseStable("Version: 13.7\nCodename: trixie main\n") == null);
    try std.testing.expectEqualStrings("trixie", known.suite);
    try std.testing.expectEqual(@as(u8, 13), known.number);
    const future = parseStable("Codename: sparrow\nVersion: 15.1\n").?;
    try std.testing.expectEqual(@as(u8, 15), future.number);
    try std.testing.expect(parseStable("Codename: sid\nVersion: 99\n") == null);
    try std.testing.expect(parseStable("Version: 13.1\n") == null);
}

test "suite metadata and security repository rules" {
    try std.testing.expectEqualStrings("12", display("bookworm"));
    try std.testing.expectEqualStrings("custom", display("custom"));
    try std.testing.expectEqual(@as(u8, 99), major("sid"));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("buster/updates", try securitySuite(arena.allocator(), "buster"));
    try std.testing.expectEqualStrings("trixie-security", try securitySuite(arena.allocator(), "trixie"));
    const repo = (try securityRepo(arena.allocator(), "https", "ftp.debian.org", "/debian/", "trixie", false)).?;
    try std.testing.expectEqualStrings("https://deb.debian.org/debian-security", repo);
    try std.testing.expect((try securityRepo(arena.allocator(), "https", "deb.debian.org", "/debian", "sid", true)) == null);
}
