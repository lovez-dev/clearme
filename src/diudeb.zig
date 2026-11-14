const std = @import("std");
const system = @import("system.zig");
const System = system.System;
const Transport = @import("transport.zig").Transport;
const Mirror = @import("mirror.zig").Mirror;
const cpio = @import("cpio.zig");
const initrd = @import("initrd.zig");

pub const Dependency = []const []const u8;
pub const Package = struct {
    name: []const u8 = "",
    filename: []const u8 = "",
    sha256: []const u8 = "",
    depends: []const Dependency = &.{},
};
pub const Index = std.StringHashMap(Package);

pub fn parseDepends(a: std.mem.Allocator, text: []const u8) ![]const Dependency {
    var groups: std.ArrayList(Dependency) = .empty;
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |part| {
        var names: std.ArrayList([]const u8) = .empty;
        var alts = std.mem.splitScalar(u8, part, '|');
        while (alts.next()) |alt| {
            var name = std.mem.trim(u8, alt, " \t\r\n");
            if (std.mem.indexOfScalar(u8, name, '(')) |i| name = std.mem.trimEnd(u8, name[0..i], " \t");
            if (std.mem.indexOfScalar(u8, name, ':')) |i| name = name[0..i];
            if (name.len > 0) try names.append(a, name);
        }
        if (names.items.len > 0) try groups.append(a, try names.toOwnedSlice(a));
    }
    return groups.toOwnedSlice(a);
}

pub fn parseIndex(a: std.mem.Allocator, text: []const u8) !Index {
    var index = Index.init(a);
    var current: Package = .{};
    var field: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.trim(u8, line, " \t").len == 0) {
            if (current.name.len > 0 and current.filename.len > 0) try index.put(current.name, current);
            current = .{};
            field = "";
            continue;
        }
        if (line[0] == ' ' or line[0] == '\t') {
            if (std.ascii.eqlIgnoreCase(field, "depends")) current.depends = try std.mem.concat(a, Dependency, &.{ current.depends, try parseDepends(a, line) });
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        field = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(field, "package")) current.name = value;
        if (std.ascii.eqlIgnoreCase(field, "filename")) current.filename = value;
        if (std.ascii.eqlIgnoreCase(field, "sha256")) current.sha256 = value;
        if (std.ascii.eqlIgnoreCase(field, "depends")) current.depends = try std.mem.concat(a, Dependency, &.{ current.depends, try parseDepends(a, value) });
    }
    if (current.name.len > 0 and current.filename.len > 0) try index.put(current.name, current);
    return index;
}

pub fn resolve(a: std.mem.Allocator, index: Index, roots: []const []const u8) ![]const []const u8 {
    var queue: std.ArrayList([]const u8) = .empty;
    var order: std.ArrayList([]const u8) = .empty;
    var seen = std.StringHashMap(void).init(a);
    try queue.appendSlice(a, roots);
    var cursor: usize = 0;
    while (cursor < queue.items.len) : (cursor += 1) {
        const name = queue.items[cursor];
        if (seen.contains(name)) continue;
        const pkg = index.get(name) orelse {
            if (order.items.len == 0) return error.MissingRootPackage;
            continue;
        };
        try seen.put(name, {});
        try order.append(a, name);
        for (pkg.depends) |alternatives| for (alternatives) |alternative| {
            if (index.contains(alternative)) {
                try queue.append(a, alternative);
                break;
            }
        };
    }
    return order.toOwnedSlice(a);
}

pub fn cleanPath(raw: []const u8) ?[]const u8 {
    const without_dot = if (std.mem.startsWith(u8, raw, "./")) raw[2..] else raw;
    const name = std.mem.trimEnd(u8, without_dot, "/");
    if (name.len == 0 or name[0] == '/' or std.mem.eql(u8, name, ".")) return null;
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return null;
    return name;
}

fn nullString(bytes: []const u8) []const u8 {
    return bytes[0 .. std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len];
}

fn number(bytes: []const u8) !u64 {
    if (bytes[0] & 0x80 != 0) {
        if (bytes[0] & 0x40 != 0) return error.InvalidTarNumber;
        var n: u64 = bytes[0] & 0x7f;
        for (bytes[1..]) |byte| n = std.math.add(u64, try std.math.mul(u64, n, 256), byte) catch return error.InvalidTarNumber;
        return n;
    }
    const text = std.mem.trim(u8, bytes, " \x00");
    return if (text.len == 0) 0 else std.fmt.parseInt(u64, text, 8) catch return error.InvalidTarNumber;
}

const Extended = struct { name: ?[]const u8 = null, link: ?[]const u8 = null };

fn pax(data: []const u8, extended: *Extended) !void {
    var cursor: usize = 0;
    while (cursor < data.len) {
        const space = std.mem.indexOfScalarPos(u8, data, cursor, ' ') orelse return error.InvalidPax;
        const length = try std.fmt.parseInt(usize, data[cursor..space], 10);
        if (length == 0 or length > data.len - cursor or cursor + length <= space + 1) return error.InvalidPax;
        const record = std.mem.trimEnd(u8, data[space + 1 .. cursor + length], "\n");
        const equals = std.mem.indexOfScalar(u8, record, '=') orelse return error.InvalidPax;
        if (std.mem.eql(u8, record[0..equals], "path")) extended.name = record[equals + 1 ..];
        if (std.mem.eql(u8, record[0..equals], "linkpath")) extended.link = record[equals + 1 ..];
        cursor += length;
    }
}

pub fn tarEntries(a: std.mem.Allocator, tar: []const u8, existing: *initrd.Names) ![]cpio.Entry {
    var entries: std.ArrayList(cpio.Entry) = .empty;
    var files = std.StringHashMap([]const u8).init(a);
    var offset: usize = 0;
    var extended: Extended = .{};
    while (offset < tar.len) {
        if (tar.len - offset < 512) return error.TruncatedTar;
        const header = tar[offset .. offset + 512];
        if (std.mem.allEqual(u8, header, 0)) break;
        var checksum: u64 = 0;
        for (header, 0..) |byte, i| checksum += if (i >= 148 and i < 156) 32 else byte;
        if (checksum != try number(header[148..156])) return error.InvalidTarChecksum;
        const size: usize = std.math.cast(usize, try number(header[124..136])) orelse return error.TarTooLarge;
        offset += 512;
        if (size > tar.len - offset) return error.TruncatedTar;
        const data = tar[offset .. offset + size];
        const padded = std.mem.alignForward(usize, size, 512);
        if (padded > tar.len - offset) return error.TruncatedTar;
        offset += padded;
        const kind = header[156];
        if (kind == 'L') {
            extended.name = std.mem.trimEnd(u8, data, "\x00\n");
            continue;
        }
        if (kind == 'K') {
            extended.link = std.mem.trimEnd(u8, data, "\x00\n");
            continue;
        }
        if (kind == 'x' or kind == 'g') {
            try pax(data, &extended);
            continue;
        }
        var raw_name = extended.name orelse nullString(header[0..100]);
        const prefix = nullString(header[345..500]);
        if (extended.name == null and prefix.len > 0 and std.mem.startsWith(u8, header[257..263], "ustar")) raw_name = try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, raw_name });
        const link = extended.link orelse nullString(header[157..257]);
        extended = .{};
        const name = cleanPath(raw_name) orelse continue;
        if (existing.contains(name)) continue;
        const mode: u32 = @intCast((try number(header[100..108])) & 0o777);
        const entry: cpio.Entry = switch (kind) {
            '5' => cpio.dir(name, mode),
            0, '0' => blk: {
                try files.put(name, data);
                break :blk cpio.file(name, mode, data);
            },
            '2' => cpio.symlink(name, link),
            '1' => blk: {
                const target = cleanPath(link) orelse continue;
                break :blk cpio.file(name, mode, files.get(target) orelse continue);
            },
            else => continue,
        };
        try entries.append(a, entry);
        try existing.put(name, {});
    }
    return entries.toOwnedSlice(a);
}

pub fn inject(sys: *System, transport: Transport, selected: Mirror, suite: []const u8, arch: []const u8, initrd_path: []const u8) ![]cpio.Entry {
    if (!sys.commandExists("dpkg-deb")) return sys.fail("dpkg-deb not found; installer SSH requires Debian dpkg", .{});
    var existing = try initrd.names(sys.io, sys.allocator, initrd_path);
    var nonce: [8]u8 = undefined;
    sys.io.random(&nonce);
    const dir = try std.fmt.allocPrint(sys.allocator, "/tmp/clearme-udeb-{x}", .{std.mem.readInt(u64, &nonce, .little)});
    try std.Io.Dir.cwd().createDir(sys.io, dir, if (@import("builtin").os.tag == .windows) .default_dir else .fromMode(0o700));
    defer std.Io.Dir.cwd().deleteTree(sys.io, dir) catch {};
    const index_path = try std.fs.path.join(sys.allocator, &.{ dir, "Packages.gz" });
    const bases = [_][]const u8{ try selected.base(sys.allocator), "https://deb.debian.org/debian" };
    var index: ?Index = null;
    var base: []const u8 = "";
    for (bases) |candidate| {
        const url = try std.fmt.allocPrint(sys.allocator, "{s}/dists/{s}/main/debian-installer/binary-{s}/Packages.gz", .{ candidate, suite, arch });
        transport.download(url, index_path) catch continue;
        if (transport.verify_signatures) {
            const compressed = sys.read(index_path, 64 << 20) catch continue;
            transport.authenticateMetadata(url, compressed) catch continue;
        }
        const body = initrd.gunzip(sys.io, sys.allocator, index_path, 64 << 20) catch continue;
        const parsed = parseIndex(sys.allocator, body) catch continue;
        if (parsed.count() == 0) continue;
        index = parsed;
        base = candidate;
        break;
    }
    const packages = index orelse return sys.fail("Cannot fetch the installer component index", .{});
    const roots: []const []const u8 = if (existing.contains("usr/bin/screen") or existing.contains("bin/screen")) &.{"openssh-server-udeb"} else &.{ "openssh-server-udeb", "screen-udeb" };
    const order = try resolve(sys.allocator, packages, roots);
    var entries: std.ArrayList(cpio.Entry) = .empty;
    for (order) |name| {
        const pkg = packages.get(name).?;
        if (pkg.sha256.len != 64 and !transport.allow_unverified) return sys.fail("Installer component {s} has no SHA-256; refusing download", .{name});
        const destination = try std.fmt.allocPrint(sys.allocator, "{s}/{s}.udeb", .{ dir, name });
        try transport.download(try std.fmt.allocPrint(sys.allocator, "{s}/{s}", .{ base, pkg.filename }), destination);
        try @import("mirror.zig").verifyFile(sys.io, destination, pkg.sha256);
        const result = try sys.capture(&.{ "dpkg-deb", "--fsys-tarfile", destination });
        if (!system.success(result.term)) return sys.fail("Failed to unpack {s}: {s}", .{ name, result.stderr });
        try entries.appendSlice(sys.allocator, try tarEntries(sys.allocator, result.stdout, &existing));
    }
    return entries.toOwnedSlice(sys.allocator);
}

test "udeb dependency alternatives and continuations form a breadth-first closure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const index = try parseIndex(a, "Package: root\nDepends: libc (>= 1), crypto | ssl,\n zlib\nFilename: pool/root.udeb\n\nPackage: libc\nFilename: libc.udeb\n\nPackage: crypto\nDepends: libc\nFilename: crypto.udeb\n\nPackage: ssl\nFilename: ssl.udeb\n\nPackage: zlib\nFilename: zlib.udeb\n");
    const order = try resolve(a, index, &.{"root"});
    try std.testing.expectEqual(@as(usize, 4), order.len);
    try std.testing.expectEqualStrings("root", order[0]);
    try std.testing.expectEqualStrings("crypto", order[2]);
    try std.testing.expectError(error.MissingRootPackage, resolve(a, index, &.{"absent"}));
    try std.testing.expect(cleanPath("a/../escape") == null);
    try std.testing.expect(cleanPath("a/..") == null);
}

test "udeb tar preserves existing libc and expands links and PAX paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var existing = initrd.Names.init(a);
    try existing.put("lib/libc.so.6", {});
    const entries = try tarEntries(a, @embedFile("testdata/udeb.tar"), &existing);
    try std.testing.expectEqual(@as(usize, 4), entries.len);
    try std.testing.expectEqualStrings("usr/bin/sshd", entries[0].name);
    try std.testing.expectEqualStrings("sshd fixture", entries[0].data);
    try std.testing.expectEqualStrings("sshd", entries[1].data);
    try std.testing.expectEqual(@as(u32, 0o120000), entries[1].mode & 0o170000);
    try std.testing.expectEqualStrings("sshd fixture", entries[2].data);
    try std.testing.expectEqualStrings("pax long path", entries[3].data);
    try std.testing.expect(!existing.contains("../escape"));
}
