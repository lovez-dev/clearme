const std = @import("std");
const Options = @import("options.zig").Options;

/// Business result of parsing: success, help, or a Chinese failure message.
/// System-level failures (OOM) travel through the error union instead.
pub const Outcome = union(enum) {
    ok: Options,
    help,
    fail: []const u8,
};

pub const ParseError = error{OutOfMemory};

const Kind = enum { str, boolean, num, list };

const Flag = struct {
    name: []const u8,
    kind: Kind,
    field: []const u8,
};

/// flag name -> Options field, one row per flag. Help texts are hand-written
/// in usage.zig, mirroring the Go version where the flag package's own output
/// was discarded and Usage() printed everything.
const flags = [_]Flag{
    .{ .name = "version", .kind = .str, .field = "suite" },
    .{ .name = "V", .kind = .boolean, .field = "program_version" },
    .{ .name = "program-version", .kind = .boolean, .field = "program_version" },
    .{ .name = "mirror", .kind = .str, .field = "mirror" },
    .{ .name = "china", .kind = .boolean, .field = "china" },
    .{ .name = "proxy", .kind = .str, .field = "proxy" },
    .{ .name = "ip", .kind = .str, .field = "ip" },
    .{ .name = "netmask", .kind = .str, .field = "netmask" },
    .{ .name = "gateway", .kind = .str, .field = "gateway" },
    .{ .name = "ipv6", .kind = .str, .field = "ipv6" },
    .{ .name = "ipv6-gateway", .kind = .str, .field = "ipv6_gateway" },
    .{ .name = "ipv6-dns", .kind = .str, .field = "ipv6_dns" },
    .{ .name = "dns", .kind = .str, .field = "dns" },
    .{ .name = "hostname", .kind = .str, .field = "hostname" },
    .{ .name = "interface", .kind = .str, .field = "interface" },
    .{ .name = "timezone", .kind = .str, .field = "timezone" },
    .{ .name = "ntp", .kind = .str, .field = "ntp" },
    .{ .name = "kernel", .kind = .str, .field = "kernel" },
    .{ .name = "cloud-kernel", .kind = .boolean, .field = "cloud_kernel" },
    .{ .name = "bpo-kernel", .kind = .boolean, .field = "bpo_kernel" },
    .{ .name = "cidata", .kind = .str, .field = "cidata" },
    .{ .name = "verify-signatures", .kind = .boolean, .field = "verify_signatures" },
    .{ .name = "keyring", .kind = .str, .field = "keyring" },
    .{ .name = "boot-mode", .kind = .str, .field = "boot_mode" },
    .{ .name = "esp", .kind = .num, .field = "esp_size" },
    .{ .name = "system-size", .kind = .str, .field = "system_size" },
    .{ .name = "hold", .kind = .num, .field = "hold" },
    .{ .name = "force-lowmem", .kind = .str, .field = "force_lowmem" },
    .{ .name = "allow-unverified", .kind = .boolean, .field = "allow_unverified" },
    .{ .name = "optimize", .kind = .boolean, .field = "optimize" },
    .{ .name = "unattended", .kind = .boolean, .field = "unattended" },
    .{ .name = "installer-ssh", .kind = .boolean, .field = "installer_ssh" },
    .{ .name = "user", .kind = .str, .field = "user" },
    .{ .name = "password", .kind = .str, .field = "password" },
    .{ .name = "ssh-port", .kind = .num, .field = "ssh_port" },
    .{ .name = "authorized-keys-url", .kind = .str, .field = "authorized_keys_url" },
    .{ .name = "disk", .kind = .str, .field = "disk" },
    .{ .name = "filesystem", .kind = .str, .field = "filesystem" },
    .{ .name = "btrfs-compress", .kind = .str, .field = "btrfs_compress" },
    .{ .name = "keep-data", .kind = .boolean, .field = "keep_data" },
    .{ .name = "keep-part", .kind = .list, .field = "keep_parts" },
    .{ .name = "install", .kind = .str, .field = "install" },
    .{ .name = "upgrade", .kind = .str, .field = "upgrade" },
    .{ .name = "post-install", .kind = .str, .field = "post_install" },
    .{ .name = "apt-repo", .kind = .list, .field = "apt_repos" },
    .{ .name = "fail2ban", .kind = .boolean, .field = "fail2ban" },
    .{ .name = "firmware", .kind = .boolean, .field = "firmware" },
    .{ .name = "swap-size", .kind = .str, .field = "swap_size" },
    .{ .name = "dry-run", .kind = .boolean, .field = "dry_run" },
    .{ .name = "reboot-now", .kind = .boolean, .field = "reboot" },
    .{ .name = "yes", .kind = .boolean, .field = "yes" },
    .{ .name = "force", .kind = .boolean, .field = "force" },
};

/// Parse flags the way Go's flag package does: `-name value`, `-name=value`
/// and a bare `-name` for booleans; `--` works as a prefix too.
/// Returned strings borrow from `arena` or are static defaults.
pub fn parse(arena: std.mem.Allocator, args: anytype) ParseError!Outcome {
    var opts: Options = .{};
    var keep_parts: std.ArrayList([]const u8) = .empty;
    var apt_repos: std.ArrayList([]const u8) = .empty;

    var idx: usize = 1; // skip argv[0]
    while (idx < args.len) : (idx += 1) {
        const raw = args[idx];
        if (std.mem.eql(u8, raw, "--") and idx + 1 == args.len) break;
        if (raw.len < 2 or raw[0] != '-')
            return .{ .fail = try std.fmt.allocPrint(arena, "Unknown option {s}", .{raw}) };

        var name: []const u8 = raw[1..];
        if (name.len > 0 and name[0] == '-') name = name[1..];

        var value: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, name, '=')) |eq| {
            value = name[eq + 1 ..];
            name = name[0..eq];
        }

        if (std.mem.eql(u8, name, "h") or std.mem.eql(u8, name, "help")) return .help;

        var matched = false;
        inline for (flags) |spec| {
            if (std.mem.eql(u8, name, spec.name)) {
                matched = true;
                switch (spec.kind) {
                    .str => {
                        const v = needValue(args, &idx, value) orelse
                            return .{ .fail = try std.fmt.allocPrint(arena, "Missing value for option {s}", .{spec.name}) };
                        @field(opts, spec.field) = v;
                        if (comptime std.mem.eql(u8, spec.name, "dns")) opts.dns_explicit = true;
                        if (comptime std.mem.eql(u8, spec.name, "ntp")) opts.ntp_explicit = true;
                    },
                    .boolean => {
                        const v = if (value) |val|
                            parseBool(val) orelse
                                return .{ .fail = try std.fmt.allocPrint(arena, "Option {s} has invalid value \"{s}\"", .{ spec.name, val }) }
                        else
                            true;
                        @field(opts, spec.field) = v;
                    },
                    .num => {
                        const v = needValue(args, &idx, value) orelse
                            return .{ .fail = try std.fmt.allocPrint(arena, "Missing value for option {s}", .{spec.name}) };
                        @field(opts, spec.field) = std.fmt.parseInt(u16, v, 10) catch
                            return .{ .fail = try std.fmt.allocPrint(arena, "Option {s} has invalid value \"{s}\"", .{ spec.name, v }) };
                    },
                    .list => {
                        const v = needValue(args, &idx, value) orelse
                            return .{ .fail = try std.fmt.allocPrint(arena, "Missing value for option {s}", .{spec.name}) };
                        if (comptime std.mem.eql(u8, spec.field, "keep_parts")) {
                            try keep_parts.append(arena, v);
                        } else {
                            try apt_repos.append(arena, std.mem.trim(u8, v, " \t\r\n"));
                        }
                    },
                }
            }
        }
        if (!matched) return .{ .fail = try std.fmt.allocPrint(arena, "Unknown option {s}", .{name}) };
    }

    opts.keep_parts = try keep_parts.toOwnedSlice(arena);
    opts.apt_repos = try apt_repos.toOwnedSlice(arena);

    if (try validate(arena, &opts)) |msg| return .{ .fail = msg };
    return .{ .ok = opts };
}

fn needValue(args: anytype, idx: *usize, inline_value: ?[]const u8) ?[]const u8 {
    if (inline_value) |v| return v;
    if (idx.* + 1 >= args.len) return null;
    idx.* += 1;
    return args[idx.*];
}

fn parseBool(s: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(s, "true") or std.ascii.eqlIgnoreCase(s, "t") or std.mem.eql(u8, s, "1")) return true;
    if (std.ascii.eqlIgnoreCase(s, "false") or std.ascii.eqlIgnoreCase(s, "f") or std.mem.eql(u8, s, "0")) return false;
    return null;
}

// ---------------------------------------------------------------------------
// validation (order mirrors Go args.go Parse)
// ---------------------------------------------------------------------------

fn validate(arena: std.mem.Allocator, o: *Options) ParseError!?[]const u8 {
    if (containsAny(o.cidata, "\r\n") or containsAny(o.keyring, "\r\n")) return "--cidata and --keyring paths must not contain newlines";
    if (o.keyring.len > 0 and !o.verify_signatures) return "--keyring requires signature verification";
    if (o.interface.len == 0 or !@import("netconf.zig").validIface(o.interface)) return "--interface is not a valid network interface name";
    if (!(std.mem.eql(u8, o.boot_mode, "auto") or std.mem.eql(u8, o.boot_mode, "bios") or std.mem.eql(u8, o.boot_mode, "efi"))) return "--boot-mode must be auto, bios or efi";
    if (o.esp_size < 106) return "--esp must be at least 106 MB";
    if (o.hold > 2) return "--hold must be 0, 1 or 2";
    if (o.hold != 0 and !o.installer_ssh) return "--hold requires installer SSH";
    if (o.force_lowmem.len > 0 and !(std.mem.eql(u8, o.force_lowmem, "0") or std.mem.eql(u8, o.force_lowmem, "1") or std.mem.eql(u8, o.force_lowmem, "2"))) return "--force-lowmem must be 0, 1 or 2";
    if (!validPathToken(o.timezone) or std.mem.indexOf(u8, o.timezone, "..") != null) return "--timezone is not a valid time zone name";
    if (!validHostToken(o.ntp)) return "--ntp is not a valid server name or address";
    if (o.kernel.len > 0 and (!validHostToken(o.kernel) or o.kernel[0] == '-')) return "--kernel is not a valid package name";
    if (o.kernel.len > 0 and o.cloud_kernel) return "--kernel and --cloud-kernel cannot be combined";
    for (o.apt_repos) |r| {
        if (!std.mem.startsWith(u8, r, "deb ") or containsAny(r, "\r\n"))
            return try std.fmt.allocPrint(arena, "--apt-repo must use 'deb URL SUITE COMPONENTS': {s}", .{r});
    }

    if (o.mirror.len > 0) if (try validateMirror(arena, o.mirror)) |m| return m;
    if (o.ip.len > 0 and !isIPv4(o.ip))
        return try std.fmt.allocPrint(arena, "--ip is not a valid IPv4 address: {s}", .{o.ip});
    if (o.netmask.len > 0) {
        if (o.ip.len == 0) return "--netmask requires --ip";
        if (!isNetmask(o.netmask))
            return try std.fmt.allocPrint(arena, "--netmask is not a valid subnet mask: {s}", .{o.netmask});
    }
    if (o.gateway.len > 0 and !isIPv4(o.gateway))
        return try std.fmt.allocPrint(arena, "--gateway is not a valid IPv4 address: {s}", .{o.gateway});

    var dns_it = std.mem.splitAny(u8, o.dns, " \t\r\n");
    while (dns_it.next()) |s| {
        if (s.len == 0) continue;
        if (!isIPLiteral(s))
            return try std.fmt.allocPrint(arena, "--dns contains an invalid address: {s}", .{s});
    }

    if (o.proxy.len > 0) if (try validateProxy(arena, o.proxy)) |m| return m;

    if (o.ssh_port < 1)
        return try std.fmt.allocPrint(arena, "Invalid --ssh-port: {d}", .{o.ssh_port});
    if (!validUsername(o.user))
        return try std.fmt.allocPrint(arena, "Invalid --user: {s}", .{o.user});

    if (std.mem.eql(u8, o.upgrade, "") or std.mem.eql(u8, o.upgrade, "none")) {
        o.upgrade = "";
    } else if (std.mem.eql(u8, o.upgrade, "safe")) {
        o.upgrade = "safe-upgrade";
    } else if (std.mem.eql(u8, o.upgrade, "full")) {
        o.upgrade = "full-upgrade";
    } else {
        return "--upgrade must be none, safe or full";
    }

    if (!validInstall(o.install)) return "--install contains unsupported characters";

    if (!(std.mem.eql(u8, o.filesystem, "ext4") or
        std.mem.eql(u8, o.filesystem, "xfs") or
        std.mem.eql(u8, o.filesystem, "btrfs")))
        return "--filesystem supports ext4, xfs or btrfs";

    if (o.btrfs_compress.len > 0) {
        if (!std.mem.eql(u8, o.filesystem, "btrfs"))
            return "--btrfs-compress requires --filesystem btrfs";
        if (!validBtrfsCompress(o.btrfs_compress))
            return "--btrfs-compress supports zstd[:1-15], zlib[:1-9] or lzo";
    }

    if (o.ipv6.len > 0) switch (checkIPv6(o.ipv6)) {
        .ok => {},
        .ipv4 => return try std.fmt.allocPrint(arena, "Invalid --ipv6: {s} is an IPv4 address", .{o.ipv6}),
        .invalid => return try std.fmt.allocPrint(arena, "Invalid --ipv6: {s} is not a valid IPv6 address", .{o.ipv6}),
    };
    if (o.ipv6_gateway.len > 0) {
        if (o.ipv6.len == 0) return "--ipv6-gateway requires --ipv6";
        if (!isPureIPv6(o.ipv6_gateway))
            return try std.fmt.allocPrint(arena, "--ipv6-gateway is not a valid IPv6 address: {s}", .{o.ipv6_gateway});
    }
    var v6dns_it = std.mem.splitAny(u8, o.ipv6_dns, " \t\r\n");
    while (v6dns_it.next()) |s| {
        if (s.len == 0) continue;
        if (!isPureIPv6(s))
            return try std.fmt.allocPrint(arena, "--ipv6-dns is not a valid IPv6 address: {s}", .{s});
    }

    if (o.swap_size.len > 0) switch (try parseSwapSize(arena, o.swap_size)) {
        .fail => |m| return m,
        .ok => |v| {
            o.swap_size = v.size;
            o.swap_mb = v.mb;
            o.swap = true;
        },
    };

    if (o.system_size.len > 0) switch (try parseSwapSize(arena, o.system_size)) {
        .fail => |m| return m,
        .ok => |v| {
            if (v.mb < 2048) return "--system-size must be at least 2G";
            o.system_size = v.size;
            o.system_size_mb = v.mb;
        },
    };

    if (o.keep_data and o.keep_parts.len > 0) return "--keep-data and --keep-part cannot be combined";
    if (o.keep_parts.len > 0) o.keep_data = true;

    if (!o.ntp_explicit) o.ntp = if (o.china) "ntp.aliyun.com" else "time.cloudflare.com";
    return null;
}

fn validHostToken(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, ".:-+", c) == null) return false;
    return true;
}

fn validPathToken(s: []const u8) bool {
    if (s.len == 0 or s[0] == '/') return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "_/+-", c) == null) return false;
    return true;
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn containsAny(haystack: []const u8, needles: []const u8) bool {
    for (haystack) |c| {
        if (std.mem.indexOfScalar(u8, needles, c) != null) return true;
    }
    return false;
}

fn hostEmpty(rest: []const u8) bool {
    var i: usize = 0;
    while (i < rest.len and rest[i] != '/' and rest[i] != '?' and rest[i] != '#') i += 1;
    return i == 0;
}

fn validateMirror(arena: std.mem.Allocator, s: []const u8) ParseError!?[]const u8 {
    const sep = std.mem.indexOf(u8, s, "://") orelse
        return try std.fmt.allocPrint(arena, "Invalid --mirror URL: {s}", .{s});
    const scheme = s[0..sep];
    if (hostEmpty(s[sep + 3 ..]))
        return try std.fmt.allocPrint(arena, "Invalid --mirror URL: {s}", .{s});
    if (!(std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https")))
        return "--mirror supports only http/https URLs";
    if (containsAny(s, " \t\r\n\"'")) return "--mirror must not contain spaces, quotes or newlines";
    _ = std.Uri.parse(s) catch return "Invalid --mirror host or port";
    return null;
}

fn validateProxy(arena: std.mem.Allocator, s: []const u8) ParseError!?[]const u8 {
    const sep = std.mem.indexOf(u8, s, "://") orelse
        return try std.fmt.allocPrint(arena, "Invalid --proxy URL: {s}", .{s});
    const scheme = s[0..sep];
    if (hostEmpty(s[sep + 3 ..]))
        return try std.fmt.allocPrint(arena, "Invalid --proxy URL: {s}", .{s});
    if (!(std.ascii.eqlIgnoreCase(scheme, "http") or
        std.ascii.eqlIgnoreCase(scheme, "https") or
        std.ascii.eqlIgnoreCase(scheme, "socks5") or
        std.ascii.eqlIgnoreCase(scheme, "socks5h")))
        return "--proxy supports only http/https/socks5/socks5h";
    if (containsAny(s, " \t\r\n\"'")) return "--proxy must not contain spaces, quotes or newlines";
    _ = std.Uri.parse(s) catch return "Invalid --proxy host or port";
    return null;
}

fn isIPv4(s: []const u8) bool {
    const ip = std.Io.net.IpAddress.parse(s, 0) catch return false;
    return switch (ip) {
        .ip4 => true,
        else => false,
    };
}

fn isPureIPv6(s: []const u8) bool {
    const ip = std.Io.net.IpAddress.parse(s, 0) catch return false;
    return switch (ip) {
        .ip6 => |v6| !mappedIPv4(v6.bytes),
        else => false,
    };
}

fn mappedIPv4(bytes: [16]u8) bool {
    for (bytes[0..10]) |b| if (b != 0) return false;
    return bytes[10] == 0xff and bytes[11] == 0xff;
}

fn isIPLiteral(s: []const u8) bool {
    const base = if (std.mem.indexOfScalar(u8, s, '%')) |i| s[0..i] else s;
    _ = std.Io.net.IpAddress.parse(base, 0) catch return false;
    return true;
}

fn isNetmask(s: []const u8) bool {
    const ip = std.Io.net.IpAddress.parse(s, 0) catch return false;
    const ip4 = switch (ip) {
        .ip4 => |a| a,
        else => return false,
    };
    var seen_zero = false;
    var count: u16 = 0;
    for (ip4.bytes) |byte| {
        var bit: u8 = 0x80;
        while (bit != 0) : (bit >>= 1) {
            if (byte & bit != 0) {
                if (seen_zero) return false;
                count += 1;
            } else seen_zero = true;
        }
    }
    return count > 0;
}

const IPv6Check = enum { ok, ipv4, invalid };

/// Validate `--ipv6`: accepts `addr` or `addr/prefix`, rejects IPv4.
fn checkIPv6(s: []const u8) IPv6Check {
    var addr = s;
    if (std.mem.indexOfScalar(u8, s, '/')) |i| {
        addr = s[0..i];
        const pfx = s[i + 1 ..];
        if (pfx.len == 0 or pfx.len > 3) return .invalid;
        for (pfx) |c| {
            if (c < '0' or c > '9') return .invalid;
        }
        const n = std.fmt.parseInt(u16, pfx, 10) catch return .invalid;
        if (n > 128) return .invalid;
    }
    const ip = std.Io.net.IpAddress.parse(addr, 0) catch return .invalid;
    return switch (ip) {
        .ip6 => |v6| if (mappedIPv4(v6.bytes)) .ipv4 else .ok,
        .ip4 => .ipv4,
    };
}

fn validUsername(s: []const u8) bool {
    if (std.mem.eql(u8, s, "root")) return true;
    if (s.len < 1 or s.len > 32) return false;
    if (s[0] < 'a' or s[0] > 'z') return false;
    for (s[1..]) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn validInstall(s: []const u8) bool {
    for (s) |c| {
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or
            c == ' ' or c == '.' or c == '_' or c == '+' or c == ':' or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// `^(zstd(:([1-9]|1[0-5]))?|zlib(:[1-9])?|lzo)$` without a regex engine.
fn validBtrfsCompress(s: []const u8) bool {
    if (std.mem.eql(u8, s, "lzo")) return true;
    if (std.mem.startsWith(u8, s, "zstd")) return checkLevel(s["zstd".len..], 15);
    if (std.mem.startsWith(u8, s, "zlib")) return checkLevel(s["zlib".len..], 9);
    return false;
}

fn checkLevel(rest: []const u8, max: u8) bool {
    if (rest.len == 0) return true;
    if (rest[0] != ':' or rest.len < 2) return false;
    if (rest.len > 2 and rest[1] == '0') return false;
    const n = std.fmt.parseInt(u8, rest[1..], 10) catch return false;
    return n >= 1 and n <= max;
}

const SwapOutcome = union(enum) {
    ok: struct { size: []const u8, mb: u32 },
    fail: []const u8,
};

/// Parse 512M / 2G / 2048 / 2048MB; range 64M..1T. Returns canonical size.
fn parseSwapSize(arena: std.mem.Allocator, raw: []const u8) ParseError!SwapOutcome {
    var upper: [24]u8 = undefined;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > upper.len)
        return .{ .fail = try std.fmt.allocPrint(arena, "Invalid --swap-size format: {s}", .{raw}) };
    for (trimmed, 0..) |c, i| upper[i] = std.ascii.toUpper(c);
    const v = upper[0..trimmed.len];

    var mult: u32 = 1;
    var num = v;
    if (std.mem.endsWith(u8, v, "MB")) {
        num = v[0 .. v.len - 2];
    } else if (std.mem.endsWith(u8, v, "GB")) {
        num = v[0 .. v.len - 2];
        mult = 1024;
    } else if (std.mem.endsWith(u8, v, "M")) {
        num = v[0 .. v.len - 1];
    } else if (std.mem.endsWith(u8, v, "G")) {
        num = v[0 .. v.len - 1];
        mult = 1024;
    } else if (std.mem.endsWith(u8, v, "K") or std.mem.endsWith(u8, v, "KB")) {
        return .{ .fail = try std.fmt.allocPrint(arena, "--swap-size minimum unit is MB: {s}", .{raw}) };
    }

    const n = std.fmt.parseInt(u32, num, 10) catch
        return .{ .fail = try std.fmt.allocPrint(arena, "Invalid --swap-size format: {s}", .{raw}) };
    if (n == 0 or n > (1 << 20) / mult)
        return .{ .fail = try std.fmt.allocPrint(arena, "--swap-size must be between 64M and 1T: {s}", .{raw}) };
    const mb = n * mult;
    if (mb < 64)
        return .{ .fail = try std.fmt.allocPrint(arena, "--swap-size must be between 64M and 1T: {s}", .{raw}) };

    if (mult == 1024)
        return .{ .ok = .{ .size = try std.fmt.allocPrint(arena, "{d}G", .{n}), .mb = mb } };
    return .{ .ok = .{ .size = try std.fmt.allocPrint(arena, "{d}M", .{mb}), .mb = mb } };
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

fn mustParse(arena: std.mem.Allocator, argv: []const []const u8) !Options {
    return switch (try parse(arena, argv)) {
        .ok => |o| o,
        .help => error.UnexpectedHelp,
        .fail => |message| {
            std.debug.print("parse failed: {s}\n", .{message});
            return error.UnexpectedFail;
        },
    };
}

fn mustFail(arena: std.mem.Allocator, argv: []const []const u8) !void {
    switch (try parse(arena, argv)) {
        .ok => return error.UnexpectedSuccess,
        .help => return error.UnexpectedHelp,
        .fail => {},
    }
}

test "default upgrade maps to full-upgrade" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();
    try std.testing.expectEqualStrings("full-upgrade", (try mustParse(gpa, &.{"clearme"})).upgrade);
    try std.testing.expectEqualStrings("", (try mustParse(gpa, &.{ "clearme", "--upgrade", "none" })).upgrade);
    try std.testing.expectEqualStrings("safe-upgrade", (try mustParse(gpa, &.{ "clearme", "--upgrade", "safe" })).upgrade);
}

test "full option set parses like the Go test" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const o = try mustParse(a.allocator(), &.{
        "clearme",                       "--version",             "12",
        "--proxy",                       "http://127.0.0.1:3128", "--mirror",
        "https://mirror.example/debian", "--ip",                  "192.0.2.10",
        "--netmask",                     "255.255.255.0",         "--gateway",
        "192.0.2.1",                     "--dns",                 "9.9.9.9 2620:fe::fe",
        "--filesystem",                  "xfs",                   "--swap-size",
        "2G",                            "--ipv6",                "2001:db8::10/64",
        "--ipv6-gateway",                "fe80::1",               "--ipv6-dns",
        "2001:4860:4860::8888",          "--install",             "nginx git",
        "--upgrade",                     "safe",                  "--post-install",
        "/tmp/post.sh",                  "--apt-repo",            "deb https://example.com/debian bookworm main",
        "--fail2ban",
    });
    try std.testing.expectEqualStrings("12", o.suite);
    try std.testing.expectEqualStrings("9.9.9.9 2620:fe::fe", o.dns);
    try std.testing.expect(o.dns_explicit);
    try std.testing.expectEqualStrings("xfs", o.filesystem);
    try std.testing.expectEqualStrings("2G", o.swap_size);
    try std.testing.expectEqual(@as(u32, 2048), o.swap_mb);
    try std.testing.expect(o.swap);
    try std.testing.expectEqualStrings("safe-upgrade", o.upgrade);
    try std.testing.expectEqual(@as(usize, 1), o.apt_repos.len);
    try std.testing.expect(o.fail2ban);
    try std.testing.expect(!o.china);
    try std.testing.expectEqualStrings("time.cloudflare.com", o.ntp);
}

test "china switches ntp" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const o = try mustParse(a.allocator(), &.{ "clearme", "--china" });
    try std.testing.expectEqualStrings("ntp.aliyun.com", o.ntp);
}

test "btrfs compress accept/reject" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();
    inline for (.{ "zstd", "zstd:1", "zstd:15", "zlib", "zlib:9", "lzo" }) |algo| {
        const o = try mustParse(gpa, &.{ "clearme", "--filesystem", "btrfs", "--btrfs-compress", algo });
        try std.testing.expectEqualStrings(algo, o.btrfs_compress);
    }
    const fails = [_][]const []const u8{
        &.{ "clearme", "--btrfs-compress", "zstd:3" },
        &.{ "clearme", "--filesystem", "ext4", "--btrfs-compress", "zstd:3" },
        &.{ "clearme", "--filesystem", "btrfs", "--btrfs-compress", "gzip" },
        &.{ "clearme", "--filesystem", "btrfs", "--btrfs-compress", "zstd:16" },
        &.{ "clearme", "--filesystem", "btrfs", "--btrfs-compress", "zlib:10" },
        &.{ "clearme", "--filesystem", "btrfs", "--btrfs-compress", "zstd:3;rm" },
    };
    for (fails) |argv| try mustFail(gpa, argv);
}

test "swap size conversion and range" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();
    const ok_cases = [_]struct { in: []const u8, size: []const u8, mb: u32 }{
        .{ .in = "512M", .size = "512M", .mb = 512 },
        .{ .in = "2G", .size = "2G", .mb = 2048 },
        .{ .in = "2g", .size = "2G", .mb = 2048 },
        .{ .in = "2048", .size = "2048M", .mb = 2048 },
        .{ .in = "2048MB", .size = "2048M", .mb = 2048 },
        .{ .in = "2GB", .size = "2G", .mb = 2048 },
    };
    for (ok_cases) |c| {
        const o = try mustParse(gpa, &.{ "clearme", "--swap-size", c.in });
        try std.testing.expectEqualStrings(c.size, o.swap_size);
        try std.testing.expectEqual(c.mb, o.swap_mb);
        try std.testing.expect(o.swap);
    }
    for ([_][]const u8{ "", "2X", "32M", "1T", "0", "512KB" }) |bad| {
        if (bad.len == 0) continue; // empty never reaches the flag
        try mustFail(gpa, &.{ "clearme", "--swap-size", bad });
    }
}

test "system size parses and enforces the minimum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const good = try mustParse(arena.allocator(), &.{ "clearme", "--system-size", "10G" });
    try std.testing.expectEqualStrings("10G", good.system_size);
    try std.testing.expectEqual(@as(u32, 10240), good.system_size_mb);
    try mustFail(arena.allocator(), &.{ "clearme", "--system-size", "1G" });
}

test "validation failures from the Go table" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();
    const table = [_][]const []const u8{
        &.{ "clearme", "--proxy", "ftp://proxy:21" },
        &.{ "clearme", "--apt-repo", "https://example.com/debian bookworm main" },
        &.{ "clearme", "--upgrade", "bad" },
        &.{ "clearme", "--install", "bad;rm" },
        &.{ "clearme", "--ssh-port", "0" },
        &.{ "clearme", "--ip", "300.1.1.1" },
        &.{ "clearme", "--ip", "192.0.2.10", "--netmask", "255.0.255.0" },
        &.{ "clearme", "--netmask", "255.255.255.0" },
        &.{ "clearme", "--gateway", "not-an-ip" },
        &.{ "clearme", "--dns", "1.1.1.1 bad" },
        &.{ "clearme", "--mirror", "ftp://mirror.example/debian" },
        &.{ "clearme", "--mirror", "https://" },
        &.{ "clearme", "--mirror", "https://mirror.example/debian extra" },
        &.{ "clearme", "--filesystem", "zfs" },
        &.{ "clearme", "--swap-size", "2X" },
        &.{ "clearme", "--swap-size", "32M" },
        &.{ "clearme", "--ipv6", "not-an-ip" },
        &.{ "clearme", "--ipv6-gateway", "fe80::1" },
        &.{ "clearme", "--ipv6", "2001:db8::10", "--ipv6-gateway", "192.0.2.1" },
        &.{ "clearme", "--ipv6-dns", "1.1.1.1" },
        &.{ "clearme", "--keep-data", "--keep-part", "/dev/sda3" },
        &.{ "clearme", "--user", "Root" },
        &.{ "clearme", "--user", "1admin" },
    };
    for (table) |argv| try mustFail(gpa, argv);
}

test "trimmed flags are rejected as unknown" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();
    const table = [_][]const []const u8{
        &.{ "clearme", "--arch", "amd64" },
        &.{ "clearme", "--debian", "12" },
        &.{ "clearme", "--dhcp" },
        &.{ "clearme", "--no-installer-ssh" },
        &.{ "clearme", "--efi" },
        &.{ "clearme", "--swap" },
        &.{ "clearme", "--loader" },
    };
    for (table) |argv| try mustFail(gpa, argv);
}

test "advanced installer controls validate and preserve explicit NTP" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const o = try mustParse(a, &.{ "clearme", "--interface", "ens3", "--timezone", "Etc/UTC", "--ntp", "time.example.org", "--china", "--cloud-kernel", "--hold", "1", "--esp", "538", "--boot-mode", "efi", "--force-lowmem", "2", "--optimize=false", "--" });
    try std.testing.expectEqualStrings("ens3", o.interface);
    try std.testing.expectEqualStrings("time.example.org", o.ntp);
    try std.testing.expectEqual(@as(u16, 1), o.hold);
    try std.testing.expect(!o.optimize and !o.allow_unverified);
    const bad = [_][]const []const u8{
        &.{ "clearme", "--hold", "3" },
        &.{ "clearme", "--hold", "1", "--installer-ssh=false" },
        &.{ "clearme", "--boot-mode", "invalid" },
        &.{ "clearme", "--esp", "1" },
        &.{ "clearme", "--timezone", "../../etc/passwd" },
        &.{ "clearme", "--ntp", "server\ncommand" },
        &.{ "clearme", "--interface", "eth0;reboot" },
        &.{ "clearme", "--kernel", "linux-image-amd64", "--cloud-kernel" },
        &.{ "clearme", "--force-lowmem", "3" },
        &.{ "clearme", "--mirror", "https://example.org:bad" },
        &.{ "clearme", "--proxy", "http://example.org:bad" },
        &.{ "clearme", "--ipv6", "::ffff:192.0.2.1" },
        &.{ "clearme", "--filesystem", "btrfs", "--btrfs-compress", "zstd:03" },
    };
    for (bad) |args| try mustFail(a, args);
}
