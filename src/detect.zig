const std = @import("std");
const builtin = @import("builtin");
const System = @import("system.zig").System;
const Options = @import("options.zig").Options;
const net = @import("netconf.zig");

pub fn hostname(sys: *System, value: []const u8) ![]const u8 {
    return sanitizeHostname(sys.allocator, if (value.len > 0) value else sys.optional(&.{"hostname"}));
}

pub fn sanitizeHostname(a: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var chars = (try std.unicode.Utf8View.init(std.mem.trim(u8, value, " \t\r\n"))).iterator();
    while (chars.nextCodepoint()) |c| try out.append(a, if (c < 128 and (std.ascii.isAlphanumeric(@intCast(c)) or c == '-')) std.ascii.toLower(@intCast(c)) else '-');
    const result = std.mem.trim(u8, out.items, "-");
    return if (result.len == 0) "localhost" else result[0..@min(63, result.len)];
}

pub fn arch(sys: *System) ![]const u8 {
    const dpkg = sys.optional(&.{ "dpkg", "--print-architecture" });
    if (dpkg.len > 0) return dpkg;
    const uname = sys.optional(&.{ "uname", "-m" });
    if (std.mem.eql(u8, uname, "x86_64")) return "amd64";
    if (std.mem.eql(u8, uname, "aarch64")) return "arm64";
    if (std.mem.eql(u8, uname, "i686") or std.mem.eql(u8, uname, "i386")) return "i386";
    if (builtin.os.tag == .windows) return switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86 => "i386",
        else => "amd64",
    };
    return sys.fail("Unsupported architecture: {s}", .{uname});
}

pub const Network = struct { config: net.Net, options: net.RenderOptions };

pub fn network(sys: *System, o: Options, number: u8) !Network {
    var n = net.detectOn(sys.io, sys.allocator, o.interface) catch |err| blk: {
        if (o.ip.len == 0 and o.ipv6.len == 0) return err;
        break :blk net.Net{};
    };
    if (o.ip.len > 0) {
        if (n.iface.len == 0) return sys.fail("No usable network interface detected for --ip", .{});
        n.ip = o.ip;
        n.gateway = o.gateway;
        n.has_v4 = true;
        n.dhcp = false;
        n.static = true;
        n.prefix = if (o.netmask.len > 0) net.maskToPrefix(o.netmask) else 24;
    } else if (n.has_v4 and o.gateway.len > 0) n.gateway = o.gateway;
    if (n.static and n.has_v4) {
        const buf = try sys.allocator.alloc(u8, 16);
        n.netmask = net.prefixToMask(buf, n.prefix) orelse return error.InvalidNetmask;
    }
    if (o.ipv6.len > 0) {
        if (n.iface.len == 0) return sys.fail("No usable network interface detected for --ipv6", .{});
        const parsed = net.parseIPv6(o.ipv6) orelse return error.InvalidIPv6;
        n.v6 = .{ .iface = n.iface, .address = parsed.addr, .prefix = parsed.prefix, .gateway = if (o.ipv6_gateway.len > 0) o.ipv6_gateway else n.v6.gateway, .static = true, .disable_ra = true, .disable_autoconf = true };
    }
    var opts: net.RenderOptions = .{ .release = number };
    try applyDNS(sys.allocator, o, &n, &opts);
    return .{ .config = n, .options = opts };
}

pub fn useEFI(sys: *System, mode: []const u8) bool {
    if (std.mem.eql(u8, mode, "efi")) return true;
    if (std.mem.eql(u8, mode, "bios")) return false;
    return sys.pathExists("/sys/firmware/efi");
}

pub fn checkFirmwareHost(sys: *System) !void {
    if (!sys.commandExists("systemd-detect-virt"))
        return sys.fail("Cannot verify --firmware host: install systemd-detect-virt or omit --firmware", .{});
    const result = try sys.capture(&.{"systemd-detect-virt"});
    if (@import("system.zig").success(result.term))
        return sys.fail("--firmware is only supported on physical machines; virtualization detected: {s}. Omit --firmware", .{std.mem.trim(u8, result.stdout, " \t\r\n")});
    switch (result.term) {
        .exited => |code| if (code == 1 and std.mem.eql(u8, std.mem.trim(u8, result.stdout, " \t\r\n"), "none")) return,
        else => {},
    }
    return sys.fail("Cannot determine virtualization status; omit --firmware", .{});
}

pub fn kernelPackage(a: std.mem.Allocator, o: Options, architecture: []const u8) ![]const u8 {
    if (o.kernel.len > 0) return o.kernel;
    if (o.cloud_kernel) {
        if (!std.mem.eql(u8, architecture, "amd64") and !std.mem.eql(u8, architecture, "arm64")) return error.UnsupportedCloudKernel;
        return std.fmt.allocPrint(a, "linux-image-cloud-{s}", .{architecture});
    }
    return std.fmt.allocPrint(a, "linux-image-{s}", .{architecture});
}

pub fn splitDNS(a: std.mem.Allocator, value: []const u8) !net.DnsPair {
    var v4: std.ArrayList([]const u8) = .empty;
    var v6: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeAny(u8, value, " \t\r\n");
    while (words.next()) |word| {
        const host = word[0 .. std.mem.indexOfScalar(u8, word, '%') orelse word.len];
        if (std.Io.net.Ip4Address.parse(host, 0)) |_| {
            try v4.append(a, word);
        } else |_| if (std.Io.net.Ip6Address.parse(host, 0)) |_| {
            try v6.append(a, word);
        } else |_| {}
    }
    return .{ .v4 = try v4.toOwnedSlice(a), .v6 = try v6.toOwnedSlice(a) };
}

pub fn applyDNS(a: std.mem.Allocator, o: Options, n: *net.Net, opts: *net.RenderOptions) !void {
    if (o.dns_explicit) {
        const pair = try splitDNS(a, o.dns);
        n.dns4 = pair.v4;
        n.dns6 = pair.v6;
    }
    if (o.ipv6_dns.len > 0) n.dns6 = (try splitDNS(a, o.ipv6_dns)).v6;
    const fallback = net.fallbackDNS(o.china);
    if (!o.dns_explicit) {
        if (n.static and n.has_v4 and n.dns4.len == 0) n.dns4 = fallback.v4;
        if (n.v6.static and n.dns6.len == 0) n.dns6 = fallback.v6;
    }
    opts.dns4 = n.dns4;
    opts.dns6 = n.dns6;
    opts.write_dns4 = n.has_v4 and n.dns4.len > 0 and (o.dns_explicit or n.static);
    opts.write_dns6 = n.v6.present() and n.dns6.len > 0 and (o.dns_explicit or o.ipv6_dns.len > 0 or n.v6.static);
}

pub fn rootDevice(sys: *System) []const u8 {
    const value = sys.optional(&.{ "findmnt", "-n", "-o", "SOURCE", "/" });
    return value[0 .. std.mem.indexOfScalar(u8, value, '[') orelse value.len];
}

pub fn rootDisks(a: std.mem.Allocator, output: []const u8) ![]const []const u8 {
    var disks: std.ArrayList([]const u8) = .empty;
    var seen = std.StringHashMap(void).init(a);
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const name = fields.next() orelse continue;
        if (!std.mem.eql(u8, fields.next() orelse "", "disk")) continue;
        const base = std.fs.path.basename(name);
        var skip = false;
        for ([_][]const u8{ "loop", "sr", "ram", "nbd" }) |prefix| if (std.mem.startsWith(u8, base, prefix)) {
            skip = true;
        };
        if (skip or seen.contains(name)) continue;
        try seen.put(name, {});
        try disks.append(a, name);
    }
    std.mem.sort([]const u8, disks.items, {}, struct {
        fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.less);
    return disks.toOwnedSlice(a);
}

pub fn disk(sys: *System, explicit: []const u8) ![]const u8 {
    if (explicit.len > 0) {
        const st = std.Io.Dir.cwd().statFile(sys.io, explicit, .{}) catch return sys.fail("Disk does not exist: {s}", .{explicit});
        if (st.kind != .block_device) return sys.fail("Not a block device: {s}", .{explicit});
        return explicit;
    }
    const root = rootDevice(sys);
    if (root.len == 0) return sys.fail("Cannot detect the root partition; specify --disk", .{});
    const disks = try rootDisks(sys.allocator, try sys.output(&.{ "lsblk", "-p", "-rn", "--inverse", "-o", "NAME,TYPE", root }));
    if (disks.len != 1) return sys.fail("Root filesystem spans {d} disks; select the target with --disk", .{disks.len});
    return disks[0];
}

pub fn normalizeDiskID(a: std.mem.Allocator, value: []const u8) ![]const u8 {
    var s: []const u8 = try std.ascii.allocLowerString(a, std.mem.trim(u8, value, " \t\r\n"));
    if (std.mem.startsWith(u8, s, "0x")) s = s[2..];
    return std.mem.trim(u8, s, "{}");
}

pub fn diskID(sys: *System, target: []const u8) ![]const u8 {
    for ([_][]const []const u8{ &.{ "lsblk", "-dn", "-o", "PTUUID", target }, &.{ "blkid", "-s", "PTUUID", "-o", "value", target } }) |argv| {
        const value = try normalizeDiskID(sys.allocator, sys.optional(argv));
        if (value.len > 0) return value;
    }
    var lines = std.mem.splitScalar(u8, sys.optional(&.{ "fdisk", "-l", target }), '\n');
    while (lines.next()) |line| {
        const lower = try std.ascii.allocLowerString(sys.allocator, line);
        if (std.mem.indexOf(u8, lower, "disk identifier") != null) if (std.mem.lastIndexOfScalar(u8, line, ':')) |i| return normalizeDiskID(sys.allocator, line[i + 1 ..]);
    }
    return "";
}

pub fn partUUID(sys: *System, target: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, sys.optional(&.{ "lsblk", "-p", "-rn", "-o", "NAME,TYPE,PARTUUID", target }), '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        _ = fields.next();
        if (!std.mem.eql(u8, fields.next() orelse "", "part")) continue;
        const id = fields.next() orelse continue;
        if (!std.mem.eql(u8, id, "-")) return id;
    }
    return "";
}

pub fn diskLabel(sys: *System, target: []const u8) ![]const u8 {
    if (!sys.commandExists("parted")) return "gpt";
    const output = sys.run(&.{ "parted", "-s", target, "print" }) catch {
        const lower = try std.ascii.allocLowerString(sys.allocator, sys.failure orelse "");
        if (std.mem.indexOf(u8, lower, "unrecognised") != null or std.mem.indexOf(u8, lower, "unrecognized") != null) return "gpt";
        return error.Failed;
    };
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| if (std.mem.indexOf(u8, line, "Partition Table:")) |i| {
        const label = std.mem.trim(u8, line[i + 16 ..], " \t\r");
        if (std.mem.eql(u8, label, "gpt") or std.mem.eql(u8, label, "msdos")) return label;
    };
    return "gpt";
}

pub fn installList(a: std.mem.Allocator, o: Options) ![]const u8 {
    var packages: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeAny(u8, o.install, " \t\r\n");
    while (words.next()) |word| try packages.append(a, word);
    const extras = [_][]const u8{ "ifupdown", if (!std.mem.eql(u8, o.user, "root")) "sudo" else "", if (o.unattended) "unattended-upgrades" else "", if (o.fail2ban) "fail2ban" else "" };
    for (extras) |extra| {
        if (extra.len == 0) continue;
        var found = false;
        for (packages.items) |pkg| if (std.mem.eql(u8, pkg, extra)) {
            found = true;
        };
        if (!found) try packages.append(a, extra);
    }
    if (o.cidata.len > 0) {
        var found = false;
        for (packages.items) |pkg| if (std.mem.eql(u8, pkg, "cloud-init")) {
            found = true;
        };
        if (!found) try packages.append(a, "cloud-init");
    }
    return std.mem.join(a, " ", packages.items);
}

pub fn kernelArgs(a: std.mem.Allocator, target: []const u8, keep: []const u32, id: []const u8, part: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "auto=true priority=critical lowmem/low=1 preseed/file=/preseed.cfg clearme_disk={s}", .{target});
    if (id.len > 0) try out.print(a, " clearme_disk_id={s}", .{id});
    if (part.len > 0) try out.print(a, " clearme_root_partuuid={s}", .{part});
    for (keep, 0..) |num, i| try out.print(a, "{s}{d}", .{ if (i == 0) " clearme_keep=" else ",", num });
    return out.toOwnedSlice(a);
}

test "hostnames, root disks and installer arguments match original behavior" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("hello-world", try sanitizeHostname(a, " Hello.World "));
    try std.testing.expectEqualStrings("localhost", try sanitizeHostname(a, "\u{e9}\u{3bb}"));
    const disks = try rootDisks(a, "/dev/sdb disk\n/dev/loop0 disk\n/dev/sda disk\n/dev/sda disk\n/dev/dm-0 lvm\n");
    try std.testing.expectEqual(@as(usize, 2), disks.len);
    try std.testing.expectEqualStrings("/dev/sda", disks[0]);
    try std.testing.expectEqualStrings("ab12", try normalizeDiskID(a, " 0xAB12 "));
    try std.testing.expectEqualStrings("auto=true priority=critical lowmem/low=1 preseed/file=/preseed.cfg clearme_disk=/dev/sda clearme_disk_id=abc clearme_root_partuuid=def clearme_keep=2,4", try kernelArgs(a, "/dev/sda", &.{ 2, 4 }, "abc", "def"));
    var n: net.Net = .{ .has_v4 = true, .static = true };
    var opts: net.RenderOptions = .{};
    try applyDNS(a, .{}, &n, &opts);
    try std.testing.expect(opts.write_dns4);
    try std.testing.expectEqual(@as(usize, 2), n.dns4.len);
    try applyDNS(a, .{ .dns_explicit = true, .dns = "9.9.9.9 2606:4700:4700::1111" }, &n, &opts);
    try std.testing.expectEqualStrings("9.9.9.9", n.dns4[0]);
    try std.testing.expectEqual(@as(usize, 1), n.dns6.len);
}
