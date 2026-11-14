const std = @import("std");
const System = @import("system.zig").System;
const Net = @import("netconf.zig").Net;

pub fn isPrivateAddress(value: []const u8) bool {
    if (std.Io.net.Ip4Address.parse(value, 0)) |ip| {
        const b = ip.bytes;
        return b[0] == 10 or b[0] == 127 or (b[0] == 172 and b[1] >= 16 and b[1] <= 31) or (b[0] == 192 and b[1] == 168) or (b[0] == 169 and b[1] == 254) or (b[0] == 100 and b[1] >= 64 and b[1] <= 127);
    } else |_| {}
    if (std.Io.net.Ip6Address.parse(value, 0)) |ip| {
        const b = ip.bytes;
        return (b[0] & 0xfe == 0xfc) or (b[0] == 0xfe and b[1] & 0xc0 == 0x80) or (std.mem.allEqual(u8, b[0..15], 0) and b[15] == 1);
    } else |_| {}
    return false;
}

pub fn extractIP(body: []const u8, v4: bool) []const u8 {
    var start: usize = 0;
    while (start < body.len) {
        while (start < body.len and !ipChar(body[start])) : (start += 1) {}
        var end = start;
        while (end < body.len and ipChar(body[end])) : (end += 1) {}
        if (end == start) break;
        const field = std.mem.trim(u8, body[start..end], ".:");
        start = end;
        if (isPrivateAddress(field)) continue;
        if (v4) {
            const ip = std.Io.net.Ip4Address.parse(field, 0) catch continue;
            if (ip.bytes[0] == 0 or ip.bytes[0] >= 224) continue;
        } else {
            const ip = std.Io.net.Ip6Address.parse(field, 0) catch continue;
            if (ip.bytes[0] == 0xff or std.mem.allEqual(u8, &ip.bytes, 0)) continue;
        }
        return field;
    }
    return "";
}

fn ipChar(c: u8) bool {
    return std.ascii.isHex(c) or c == ':' or c == '.';
}

const Probe = struct {
    io: std.Io,
    v4: bool,
    result: [64]u8 = undefined,
    length: usize = 0,

    fn run(self: *Probe) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const urls: []const []const u8 = if (self.v4) &.{ "https://api.ipify.org", "https://myip.ipip.net", "https://ip.3322.net", "https://ipv4.icanhazip.com", "https://www.taobao.com/help/getip.php" } else &.{ "https://api6.ipify.org", "https://ipv6.icanhazip.com", "https://test-ipv6.com/ip/" };
        const start = std.Io.Clock.awake.now(self.io).nanoseconds;
        for (urls) |url| {
            const elapsed = std.Io.Clock.awake.now(self.io).nanoseconds - start;
            const remaining = @as(i96, 4_000_000_000) - elapsed;
            if (remaining <= 0) return;
            const seconds = std.fmt.allocPrint(arena.allocator(), "{d}", .{@max(1, @divTrunc(@min(remaining, 3_000_000_000), 1_000_000_000))}) catch return;
            const result = std.process.run(arena.allocator(), self.io, .{
                .argv = &.{ "curl", "--silent", "--fail", "--location", "--noproxy", "*", if (self.v4) "--ipv4" else "--ipv6", "--max-time", seconds, "--url", url },
                .stdout_limit = .limited(4096),
                .stderr_limit = .limited(4096),
                .timeout = .{ .duration = .{ .clock = .awake, .raw = .{ .nanoseconds = remaining } } },
            }) catch continue;
            if (!@import("system.zig").success(result.term)) continue;
            const ip = extractIP(result.stdout, self.v4);
            if (ip.len == 0 or ip.len > self.result.len) continue;
            @memcpy(self.result[0..ip.len], ip);
            self.length = ip.len;
            return;
        }
    }
};

pub fn loginAddresses(sys: *System, n: Net) !struct { v4: []const u8, v6: []const u8 } {
    var v4 = if (n.has_v4) n.ip else "";
    var v6 = if (n.v6.present()) n.v6.address else "";
    var probes = [_]Probe{ .{ .io = sys.io, .v4 = true }, .{ .io = sys.io, .v4 = false } };
    var threads: [2]?std.Thread = .{ null, null };
    defer for (threads) |thread| if (thread) |t| t.join();
    if (isPrivateAddress(v4)) threads[0] = try std.Thread.spawn(.{}, Probe.run, .{&probes[0]});
    if (isPrivateAddress(v6)) threads[1] = try std.Thread.spawn(.{}, Probe.run, .{&probes[1]});
    for (&threads) |*thread| if (thread.*) |t| {
        t.join();
        thread.* = null;
    };
    if (probes[0].length > 0) v4 = try sys.allocator.dupe(u8, probes[0].result[0..probes[0].length]);
    if (probes[1].length > 0) v6 = try sys.allocator.dupe(u8, probes[1].result[0..probes[1].length]);
    return .{ .v4 = v4, .v6 = v6 };
}

test "public address extraction accepts text and JSON, excluding private and CGNAT" {
    try std.testing.expect(isPrivateAddress("100.100.1.1"));
    try std.testing.expect(isPrivateAddress("fd00::1"));
    try std.testing.expectEqualStrings("1.2.3.4", extractIP("Current IP: 1.2.3.4", true));
    try std.testing.expectEqualStrings("2606:4700::1111", extractIP("{\"ip\":\"2606:4700::1111\"}", false));
    try std.testing.expectEqualStrings("", extractIP("10.0.0.1 100.64.0.1", true));
}
