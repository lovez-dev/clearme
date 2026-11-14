//! Bounded HTTP transfers through curl, including HTTP(S)/SOCKS proxies,
//! redirects, retry, and resumable installer downloads.
const std = @import("std");
const system = @import("system.zig");
const System = system.System;
const mirror = @import("mirror.zig");
const signing = @import("signing.zig");

pub const Transport = struct {
    sys: *System,
    proxy: []const u8 = "",
    allow_unverified: bool = false,
    verify_signatures: bool = true,
    keyring: []const u8 = "",

    fn args(self: Transport, url: []const u8, seconds: u32) !std.ArrayList([]const u8) {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(self.sys.allocator, &.{
            "curl",       "--silent",                                                    "--show-error", "--fail",  "--location", "--connect-timeout", "15",
            "--max-time", try std.fmt.allocPrint(self.sys.allocator, "{d}", .{seconds}), "--user-agent", "clearme",
        });
        if (self.proxy.len > 0) try argv.appendSlice(self.sys.allocator, &.{ "--proxy", self.proxy });
        try argv.appendSlice(self.sys.allocator, &.{ "--url", url });
        return argv;
    }

    pub fn fetchText(self: Transport, url: []const u8, limit: usize) ![]const u8 {
        const argv = try self.args(url, 60);
        const result = std.process.run(self.sys.allocator, self.sys.io, .{
            .argv = argv.items,
            .stdout_limit = .limited(std.math.add(usize, limit, 1) catch return error.StreamTooLong),
            .stderr_limit = .limited(1 << 20),
            .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(65) } },
        }) catch |err| return self.sys.fail("Failed to read {s}: {s}", .{ url, @errorName(err) });
        if (!system.success(result.term)) return self.sys.fail("Failed to read {s}: {s}", .{ url, result.stderr });
        if (result.stdout.len > limit) return error.StreamTooLong;
        return result.stdout;
    }

    pub fn ping(self: Transport, url: []const u8) bool {
        var argv = self.args(url, 20) catch return false;
        tryAppend(&argv, self.sys.allocator, &.{ "--range", "0-0", "--output", if (@import("builtin").os.tag == .windows) "NUL" else "/dev/null", "--write-out", "%{http_code}" }) catch return false;
        const result = std.process.run(self.sys.allocator, self.sys.io, .{
            .argv = argv.items,
            .stdout_limit = .limited(64),
            .stderr_limit = .limited(4096),
            .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(25) } },
        }) catch return false;
        return system.success(result.term) and (std.mem.eql(u8, result.stdout, "200") or std.mem.eql(u8, result.stdout, "206"));
    }

    pub fn download(self: Transport, url: []const u8, destination: []const u8) !void {
        const part = try std.fmt.allocPrint(self.sys.allocator, "{s}.part", .{destination});
        const cwd = std.Io.Dir.cwd();
        for (0..3) |attempt| {
            if (attempt > 0) try std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromSeconds(@intCast(attempt * 3)) }, self.sys.io);
            const size = if (cwd.statFile(self.sys.io, part, .{})) |stat| stat.size else |_| 0;
            var argv = try self.args(url, 1800);
            try argv.appendSlice(self.sys.allocator, &.{ "--output", part, "--write-out", "%{http_code}" });
            if (size > 0) try argv.appendSlice(self.sys.allocator, &.{ "--continue-at", "-" });
            const result = std.process.run(self.sys.allocator, self.sys.io, .{
                .argv = argv.items,
                .stdout_limit = .limited(64),
                .stderr_limit = .limited(1 << 20),
                .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(1810) } },
            }) catch |err| {
                self.sys.failure = try std.fmt.allocPrint(self.sys.allocator, "Download failed for {s}: {s}", .{ url, @errorName(err) });
                continue;
            };
            const status = std.mem.trim(u8, result.stdout, " \r\n");
            if (system.success(result.term) and (std.mem.eql(u8, status, "200") or (size > 0 and std.mem.eql(u8, status, "206")))) {
                try cwd.rename(part, cwd, destination, self.sys.io);
                return;
            }
            const resume_failed = switch (result.term) {
                .exited => |code| code == 33 or code == 36,
                else => false,
            };
            if (resume_failed or std.mem.eql(u8, status, "416") or (size == 0 and std.mem.eql(u8, status, "206"))) self.sys.remove(part);
            self.sys.failure = try std.fmt.allocPrint(self.sys.allocator, "Download failed for {s}: HTTP {s} {s}", .{ url, status, result.stderr });
        }
        return error.Failed;
    }

    pub fn fetchChecksums(self: Transport, base: []const u8) !mirror.Checksums {
        const a = self.sys.allocator;
        var failures: std.ArrayList(u8) = .empty;
        for (try mirror.checksumCandidates(self.sys.allocator, base)) |url| {
            const text = self.fetchText(url, 1 << 20) catch {
                const detail = self.sys.failure orelse "request failed";
                try failures.appendSlice(a, try std.fmt.allocPrint(a, "{s}: {s}\n", .{ url, detail }));
                continue;
            };
            if (self.verify_signatures) self.authenticateMetadata(url, text) catch |err| {
                const detail = self.sys.failure orelse @errorName(err);
                try failures.appendSlice(a, try std.fmt.allocPrint(a, "{s}: signed metadata verification failed: {s}\n", .{ url, detail }));
                continue;
            };
            const sums = try mirror.parseChecksums(a, text);
            if (sums.count() > 0) return mirror.selectNetbootSums(a, sums, mirror.netbootPrefix(base));
            try failures.appendSlice(a, try std.fmt.allocPrint(a, "{s}: no valid SHA-256 entries\n", .{url}));
        }
        return self.sys.fail("No usable SHA-256 metadata for {s}:\n{s}", .{ base, if (failures.items.len > 0) failures.items else "no checksum locations were available" });
    }

    pub fn fetchRelease(self: Transport, root: []const u8, suite: []const u8) ![]const u8 {
        const a = self.sys.allocator;
        const base = try std.fmt.allocPrint(a, "{s}/dists/{s}", .{ root, suite });
        if (!self.verify_signatures) return self.fetchText(try std.fmt.allocPrint(a, "{s}/Release", .{base}), 16 << 20);
        const scratch = try signing.Scratch.init(self.sys);
        defer scratch.deinit();
        const signed = self.fetchText(try std.fmt.allocPrint(a, "{s}/InRelease", .{base}), 16 << 20);
        const text = if (signed) |bytes|
            try scratch.verify(self.keyring, bytes, null)
        else |_| blk: {
            const release = try self.fetchText(try std.fmt.allocPrint(a, "{s}/Release", .{base}), 16 << 20);
            const signature = try self.fetchText(try std.fmt.allocPrint(a, "{s}/Release.gpg", .{base}), 1 << 20);
            break :blk try scratch.verify(self.keyring, release, signature);
        };
        const code = signing.codename(text) orelse return error.MissingReleaseCodename;
        const alias = std.mem.eql(u8, suite, "stable") or std.mem.eql(u8, suite, "oldstable") or std.mem.eql(u8, suite, "oldoldstable") or std.mem.eql(u8, suite, "testing") or std.mem.eql(u8, suite, "unstable");
        if (!alias and !std.mem.eql(u8, suite, code)) return self.sys.fail("Signed repository codename {s} does not match requested {s}", .{ code, suite });
        return text;
    }

    pub fn authenticateMetadata(self: Transport, url: []const u8, bytes: []const u8) !void {
        const a = self.sys.allocator;
        if (archiveLocation(url)) |location| {
            const release = try self.fetchRelease(location.root, location.suite);
            const digest = try signing.releaseDigest(release, location.path);
            try signing.verifyBytes(bytes, digest);
        } else {
            // Firmware and custom checksum directories use detached signatures.
            // Daily images have no archive Release; unsigned metadata fails here.
            const signature = self.fetchText(try std.fmt.allocPrint(a, "{s}.sign", .{url}), 1 << 20) catch
                try self.fetchText(try std.fmt.allocPrint(a, "{s}.gpg", .{url}), 1 << 20);
            const scratch = try signing.Scratch.init(self.sys);
            defer scratch.deinit();
            _ = try scratch.verify(self.keyring, bytes, signature);
        }
    }

    pub fn byLatency(self: Transport, candidates: []const mirror.Mirror, suite: []const u8) ![]const mirror.Mirror {
        const a = self.sys.allocator;
        const probes = try a.alloc(Probe, candidates.len);
        const threads = try a.alloc(std.Thread, candidates.len);
        var started: usize = 0;
        defer for (threads[0..started]) |thread| thread.join();
        for (candidates, 0..) |candidate, i| {
            probes[i] = .{ .io = self.sys.io, .proxy = self.proxy, .candidate = candidate, .suite = suite };
            threads[i] = try std.Thread.spawn(.{}, Probe.run, .{&probes[i]});
            started += 1;
        }
        for (threads[0..started]) |thread| thread.join();
        started = 0;
        std.mem.sort(Probe, probes, {}, struct {
            fn less(_: void, lhs: Probe, rhs: Probe) bool {
                return lhs.elapsed < rhs.elapsed;
            }
        }.less);
        var result: std.ArrayList(mirror.Mirror) = .empty;
        for (probes) |probe| if (probe.ok) {
            try result.append(a, probe.candidate);
        };
        return result.toOwnedSlice(a);
    }
};

const ArchiveLocation = struct { root: []const u8, suite: []const u8, path: []const u8 };

fn archiveLocation(url: []const u8) ?ArchiveLocation {
    const start = std.mem.indexOf(u8, url, "/dists/") orelse return null;
    const rest = url[start + 7 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    if (slash == 0 or slash + 1 == rest.len) return null;
    return .{ .root = url[0..start], .suite = rest[0..slash], .path = rest[slash + 1 ..] };
}

fn tryAppend(list: *std.ArrayList([]const u8), a: std.mem.Allocator, items: []const []const u8) !void {
    try list.appendSlice(a, items);
}

const Probe = struct {
    io: std.Io,
    proxy: []const u8,
    candidate: mirror.Mirror,
    suite: []const u8,
    ok: bool = false,
    elapsed: i96 = std.math.maxInt(i96),

    fn run(self: *Probe) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var sys: System = .{ .io = self.io, .allocator = arena.allocator() };
        const transport: Transport = .{ .sys = &sys, .proxy = self.proxy };
        const url = self.candidate.releaseURL(sys.allocator, self.suite) catch return;
        const start = std.Io.Clock.awake.now(self.io);
        self.ok = transport.ping(url);
        self.elapsed = std.Io.Clock.awake.now(self.io).nanoseconds - start.nanoseconds;
    }
};
