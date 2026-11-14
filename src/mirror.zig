//! Debian mirror URLs and fallback order, matching internal/mirror.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Mirror = struct {
    protocol: []const u8 = "https",
    host: []const u8,
    directory: []const u8 = "/debian",

    pub fn base(self: Mirror, arena: Allocator) ![]const u8 {
        const dir = self.directory;
        const trimmed = if (std.mem.endsWith(u8, dir, "/")) dir[0 .. dir.len - 1] else dir;
        return std.fmt.allocPrint(arena, "{s}://{s}{s}", .{ self.protocol, self.host, trimmed });
    }

    pub fn netbootDir(self: Mirror, arena: Allocator, suite: []const u8, arch: []const u8) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}/dists/{s}/main/installer-{s}/current/images/netboot/debian-installer/{s}", .{ try self.base(arena), suite, arch, arch });
    }

    pub fn releaseURL(self: Mirror, arena: Allocator, suite: []const u8) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}/dists/{s}/Release", .{ try self.base(arena), suite });
    }
};

pub fn dailyNetbootDir(arena: Allocator, arch: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "https://d-i.debian.org/daily-images/{s}/daily/netboot/debian-installer/{s}", .{ arch, arch });
}

pub const china_mirrors = [_]Mirror{
    .{ .host = "mirrors.aliyun.com" },
    .{ .host = "mirrors.tuna.tsinghua.edu.cn" },
    .{ .host = "mirrors.ustc.edu.cn" },
    .{ .host = "mirrors.cloud.tencent.com" },
    .{ .host = "repo.huaweicloud.com" },
};

pub fn candidates(user: ?Mirror) [4]Mirror {
    const official: Mirror = .{ .host = "deb.debian.org" };
    const aws: Mirror = .{ .host = "cdn-aws.deb.debian.org" };
    const archive: Mirror = .{ .host = "archive.debian.org" };
    if (user) |m| {
        if (m.host.len > 0) return .{ m, official, aws, archive };
    }
    return .{ official, aws, .{ .host = "ftp.debian.org" }, archive };
}

test "mirror URLs preserve archive paths and architectures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m: Mirror = .{ .protocol = "http", .host = "example.org:8080", .directory = "/debian/" };
    try std.testing.expectEqualStrings("http://example.org:8080/debian", try m.base(a));
    try std.testing.expectEqualStrings("http://example.org:8080/debian/dists/trixie/Release", try m.releaseURL(a, "trixie"));
    try std.testing.expectEqualStrings("http://example.org:8080/debian/dists/bookworm/main/installer-arm64/current/images/netboot/debian-installer/arm64", try m.netbootDir(a, "bookworm", "arm64"));
    try std.testing.expectEqualStrings("https://d-i.debian.org/daily-images/amd64/daily/netboot/debian-installer/amd64", try dailyNetbootDir(a, "amd64"));
}

test "candidate priority and empty user fallback" {
    const defaults = candidates(null);
    const empty = candidates(.{ .host = "" });
    for (defaults, empty) |left, right| try std.testing.expectEqualStrings(left.host, right.host);
    try std.testing.expectEqualStrings("deb.debian.org", defaults[0].host);
    try std.testing.expectEqualStrings("ftp.debian.org", defaults[2].host);
    const custom = candidates(.{ .host = "custom.example", .directory = "/archive" });
    try std.testing.expectEqualStrings("custom.example", custom[0].host);
    try std.testing.expectEqualStrings("/archive", custom[0].directory);
    try std.testing.expectEqualStrings("deb.debian.org", custom[1].host);
    try std.testing.expectEqualStrings("cdn-aws.deb.debian.org", custom[2].host);
    try std.testing.expectEqualStrings("archive.debian.org", custom[3].host);
}

/// Results and checksum keys are owned by the caller's arena.
pub fn checksumCandidates(arena: Allocator, raw_base: []const u8) ![]const []const u8 {
    const base = if (std.mem.endsWith(u8, raw_base, "/")) raw_base[0 .. raw_base.len - 1] else raw_base;
    var urls: std.ArrayList([]const u8) = .empty;
    if (std.mem.indexOf(u8, base, "/netboot/")) |i| {
        if (i > 0) try urls.append(arena, try std.fmt.allocPrint(arena, "{s}/SHA256SUMS", .{base[0..i]}));
    }
    try urls.append(arena, try std.fmt.allocPrint(arena, "{s}/SHA256SUMS", .{base}));
    return urls.toOwnedSlice(arena);
}

pub const Checksums = std.StringHashMap([64]u8);

/// Fetch a small resource with a hard response-body bound. The caller owns
/// client lifetime and proxy configuration; returned storage belongs to arena.
pub fn fetchText(client: *std.http.Client, arena: Allocator, url: []const u8, limit: usize) ![]const u8 {
    const capacity = std.math.add(usize, limit, 1) catch return error.StreamTooLong;
    const buffer = try arena.alloc(u8, capacity);
    var writer = std.Io.Writer.fixed(buffer);
    const response = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &writer,
        .headers = .{ .accept_encoding = .default },
        .redirect_behavior = .unhandled,
    }) catch |err| {
        if (err == error.WriteFailed and writer.buffered().len > limit) return error.StreamTooLong;
        return err;
    };
    if (response.status != .ok) return error.HttpStatus;
    if (writer.buffered().len > limit) return error.StreamTooLong;
    return writer.buffered();
}

/// Try parent and local SHA256SUMS in order, then select this installer variant.
pub const Probe = struct { mirror: Mirror, latency_ns: i96 };

/// Range probe accepts both 200 (servers ignoring Range) and 206.
pub fn ping(client: *std.http.Client, url: []const u8) bool {
    const response = client.fetch(.{
        .location = .{ .url = url },
        .headers = .{ .range = .{ .bytes = .{ .first = 0, .last = 0 } } },
        .redirect_behavior = .unhandled,
    }) catch return false;
    if (response.status != .ok and response.status != .partial_content) return false;
    return true;
}

const ProbeJob = struct {
    io: std.Io,
    allocator: Allocator,
    mirror: Mirror,
    suite: []const u8,
    result: *?Probe,
};

fn probeWorker(job: ProbeJob) void {
    var arena_state = std.heap.ArenaAllocator.init(job.allocator);
    defer arena_state.deinit();
    var client: std.http.Client = .{ .allocator = job.allocator, .io = job.io };
    defer client.deinit();
    const start = std.Io.Clock.awake.now(job.io);
    const url = job.mirror.releaseURL(arena_state.allocator(), job.suite) catch return;
    if (!ping(&client, url)) return;
    const end = std.Io.Clock.awake.now(job.io);
    job.result.* = .{ .mirror = job.mirror, .latency_ns = end.nanoseconds - start.nanoseconds };
}

/// Probe concurrently; each worker owns its HTTP client and results are sorted
/// by monotonic elapsed time. Unreachable candidates are omitted.
pub fn byLatency(io: std.Io, allocator: Allocator, cands: []const Mirror, suite: []const u8) ![]const Probe {
    const results = try allocator.alloc(?Probe, cands.len);
    @memset(results, null);
    const threads = try allocator.alloc(std.Thread, cands.len);
    for (cands, 0..) |mirror, i| {
        threads[i] = try std.Thread.spawn(.{}, probeWorker, .{ProbeJob{
            .io = io,
            .allocator = allocator,
            .mirror = mirror,
            .suite = suite,
            .result = &results[i],
        }});
    }
    for (threads) |thread| thread.join();
    var reachable: std.ArrayList(Probe) = .empty;
    for (results) |item| if (item) |probe| try reachable.append(allocator, probe);
    std.mem.sort(Probe, reachable.items, {}, struct {
        fn lessThan(_: void, a: Probe, b: Probe) bool {
            return a.latency_ns < b.latency_ns;
        }
    }.lessThan);
    return reachable.toOwnedSlice(allocator);
}

/// Probe installer linux files in candidate order and return the first hit.
pub fn select(io: std.Io, allocator: Allocator, cands: []const Mirror, suite: []const u8, arch: []const u8) !Mirror {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    for (cands) |mirror| {
        const base = try mirror.netbootDir(arena_state.allocator(), suite, arch);
        const url = try std.fmt.allocPrint(arena_state.allocator(), "{s}/linux", .{base});
        var client: std.http.Client = .{ .allocator = allocator, .io = io };
        defer client.deinit();
        if (ping(&client, url)) return mirror;
    }
    return error.NoMirrorAvailable;
}
pub fn fetchChecksums(client: *std.http.Client, arena: Allocator, base: []const u8) !Checksums {
    var last_error: anyerror = error.NoChecksums;
    for (try checksumCandidates(arena, base)) |url| {
        const text = fetchText(client, arena, url, 1 << 20) catch |err| {
            last_error = err;
            continue;
        };
        const sums = try parseChecksums(arena, text);
        if (sums.count() > 0) return selectNetbootSums(arena, sums, netbootPrefix(base));
        last_error = error.NoChecksums;
    }
    return last_error;
}

test "fetchText rejects invalid URLs and overflowing limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    try std.testing.expectError(error.StreamTooLong, fetchText(&client, arena.allocator(), "http://localhost/", std.math.maxInt(usize)));
    if (fetchText(&client, arena.allocator(), ":invalid", 32)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

/// Empty expected hashes deliberately skip IO, matching the Go implementation.
pub fn verifyFile(io: std.Io, path: []const u8, want: []const u8) !void {
    if (want.len == 0) return;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var reader = file.readerStreaming(io, &.{});
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [16384]u8 = undefined;
    while (true) {
        const n = try reader.interface.readSliceShort(&buffer);
        hasher.update(buffer[0..n]);
        if (n < buffer.len) break;
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    try verifyDigest(digest, want);
}

fn verifyDigest(digest: [32]u8, want: []const u8) !void {
    if (want.len != 64) return error.ChecksumMismatch;
    const hex = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        if (std.ascii.toLower(want[i * 2]) != hex[byte >> 4] or
            std.ascii.toLower(want[i * 2 + 1]) != hex[byte & 15])
            return error.ChecksumMismatch;
    }
}

test "SHA256 comparison accepts uppercase and rejects corrupt hashes" {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("abc");
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    try verifyDigest(digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    try verifyDigest(digest, "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD");
    try std.testing.expectError(error.ChecksumMismatch, verifyDigest(digest, "bad"));
    try std.testing.expectError(error.ChecksumMismatch, verifyDigest(digest, "0000000000000000000000000000000000000000000000000000000000000000"));
}

test "file verification streams content and skips absent optional hashes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "payload", .data = "abc" });
    const path = try tmp.dir.realPathFileAlloc(io, "payload", std.testing.allocator);
    defer std.testing.allocator.free(path);
    try verifyFile(io, path, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    try std.testing.expectError(error.ChecksumMismatch, verifyFile(io, path, "bad"));
    try verifyFile(io, "missing-optional-file", "");
}

pub fn netbootPrefix(raw_base: []const u8) []const u8 {
    const base = if (std.mem.endsWith(u8, raw_base, "/")) raw_base[0 .. raw_base.len - 1] else raw_base;
    const i = std.mem.indexOf(u8, base, "/netboot/") orelse return "";
    return base[i + 1 ..];
}

fn isNetboot(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "netboot/") or std.mem.indexOf(u8, name, "/netboot/") != null;
}

pub fn selectNetbootSums(arena: Allocator, sums: Checksums, prefix: []const u8) !Checksums {
    var filtered = Checksums.init(arena);
    const path_prefix = try std.fmt.allocPrint(arena, "{s}/", .{prefix});
    var it = sums.iterator();
    while (it.next()) |entry| {
        if (prefix.len > 0 and std.mem.startsWith(u8, entry.key_ptr.*, path_prefix))
            try filtered.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    if (filtered.count() == 0) {
        var has_netboot = false;
        it = sums.iterator();
        while (it.next()) |entry| {
            if (isNetboot(entry.key_ptr.*)) has_netboot = true;
        }
        it = sums.iterator();
        while (it.next()) |entry| {
            if (!has_netboot or isNetboot(entry.key_ptr.*))
                try filtered.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    // Count before adding aliases: inserting into filtered invalidates iterators.
    const Alias = struct { count: usize, hash: [64]u8 };
    var aliases = std.StringHashMap(Alias).init(arena);
    var selected = filtered.iterator();
    while (selected.next()) |entry| {
        const name = entry.key_ptr.*;
        const short = if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| name[i + 1 ..] else name;
        const alias = try aliases.getOrPut(short);
        if (!alias.found_existing) alias.value_ptr.* = .{ .count = 0, .hash = entry.value_ptr.* };
        alias.value_ptr.count += 1;
    }
    var alias_it = aliases.iterator();
    while (alias_it.next()) |entry| {
        if (entry.value_ptr.count == 1 and !filtered.contains(entry.key_ptr.*))
            try filtered.put(entry.key_ptr.*, entry.value_ptr.hash);
    }
    return filtered;
}

test "netboot sums distinguish installer variants and ambiguous aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sums = Checksums.init(a);
    const regular: [64]u8 = @splat('b');
    const other: [64]u8 = @splat('c');
    try sums.put("netboot/debian-installer/amd64/linux", regular);
    try sums.put("netboot/gtk/debian-installer/amd64/linux", other);
    try sums.put("cdrom/linux", other);
    const prefix = netbootPrefix("https://example.org/images/netboot/debian-installer/amd64/");
    const exact = try selectNetbootSums(a, sums, prefix);
    try std.testing.expectEqualStrings(&regular, &exact.get("linux").?);
    try std.testing.expectEqual(@as(u32, 2), exact.count());
    const fallback = try selectNetbootSums(a, sums, "missing");
    try std.testing.expect(!fallback.contains("linux"));
    try std.testing.expect(!fallback.contains("cdrom/linux"));
    var flat = Checksums.init(a);
    try flat.put("linux", regular);
    const direct = try selectNetbootSums(a, flat, "");
    try std.testing.expectEqualStrings(&regular, &direct.get("linux").?);
    try std.testing.expectEqualStrings("", netbootPrefix("https://example.org/files"));
}

pub fn parseChecksums(arena: Allocator, text: []const u8) !Checksums {
    var sums = Checksums.init(arena);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t\r\x0b\x0c");
        const hash = fields.next() orelse continue;
        var name = fields.next() orelse continue;
        if (hash.len != 64 or fields.next() != null) continue;
        var normalized: [64]u8 = undefined;
        var valid = true;
        for (hash, 0..) |c, i| {
            if (!std.ascii.isHex(c)) {
                valid = false;
                break;
            }
            normalized[i] = std.ascii.toLower(c);
        }
        if (!valid) continue;
        if (std.mem.startsWith(u8, name, "*")) name = name[1..];
        if (std.mem.startsWith(u8, name, "./")) name = name[2..];
        try sums.put(try arena.dupe(u8, name), normalized);
    }
    return sums;
}

test "checksum locations prefer images or daily parent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m: Mirror = .{ .host = "deb.debian.org" };
    const urls = try checksumCandidates(a, try m.netbootDir(a, "trixie", "amd64"));
    try std.testing.expectEqual(@as(usize, 2), urls.len);
    try std.testing.expectEqualStrings("https://deb.debian.org/debian/dists/trixie/main/installer-amd64/current/images/SHA256SUMS", urls[0]);
    const daily = try checksumCandidates(a, try dailyNetbootDir(a, "amd64"));
    try std.testing.expectEqualStrings("https://d-i.debian.org/daily-images/amd64/daily/SHA256SUMS", daily[0]);
    const direct = try checksumCandidates(a, "https://example.org/files/");
    try std.testing.expectEqual(@as(usize, 1), direct.len);
    try std.testing.expectEqualStrings("https://example.org/files/SHA256SUMS", direct[0]);
}

test "checksum parser normalizes hashes and rejects malformed lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sums = try parseChecksums(arena.allocator(), "# comment\n" ++ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++ "  linux\n" ++ "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB" ++ " *./initrd.gz\n" ++ "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg" ++ " invalid\n" ++ "ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" ++ " short\n" ++ "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" ++ " name extra\n");
    try std.testing.expectEqual(@as(u32, 2), sums.count());
    try std.testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", &sums.get("linux").?);
    try std.testing.expectEqualStrings("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", &sums.get("initrd.gz").?);
}
