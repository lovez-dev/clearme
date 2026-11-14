//! Verify metadata with local trust anchors. Keys are never fetched from the mirror.
const std = @import("std");
const builtin = @import("builtin");
const System = @import("system.zig").System;
const success = @import("system.zig").success;

pub const archive_keyring = "/usr/share/keyrings/debian-archive-keyring.gpg";
pub const role_keyring = "/usr/share/keyrings/debian-role-keys.gpg";

pub fn check(sys: *System, keyring: []const u8) !void {
    if (!sys.commandExists("gpgv")) return sys.fail("Signature verification requires gpgv; install it or explicitly use --verify-signatures=false", .{});
    const path = if (keyring.len > 0) keyring else archive_keyring;
    if (!sys.pathExists(path)) return sys.fail("Trusted keyring {s} not found; update debian-archive-keyring or provide a local --keyring", .{path});
}

pub const Scratch = struct {
    sys: *System,
    path: []const u8,

    pub fn init(sys: *System) !Scratch {
        var nonce: [16]u8 = undefined;
        sys.io.random(&nonce);
        const relative = try std.fmt.allocPrint(sys.allocator, "{s}clearme-signature-{x}", .{ if (builtin.os.tag == .linux) "/tmp/" else "", nonce });
        try std.Io.Dir.cwd().createDir(sys.io, relative, if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700));
        return .{ .sys = sys, .path = relative };
    }

    pub fn deinit(self: Scratch) void {
        std.Io.Dir.cwd().deleteTree(self.sys.io, self.path) catch {};
    }

    fn file(self: Scratch, name: []const u8) ![]const u8 {
        return std.fs.path.join(self.sys.allocator, &.{ self.path, name });
    }

    pub fn verify(self: Scratch, keyring: []const u8, signed_data: []const u8, signature: ?[]const u8) ![]const u8 {
        const sys = self.sys;
        const input = try self.file("metadata");
        const output = try self.file("verified");
        try sys.write(input, signed_data, 0o600);
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(sys.allocator, &.{ "gpgv", "--homedir", self.path, "--status-fd", "1" });
        if (keyring.len > 0) {
            try argv.appendSlice(sys.allocator, &.{ "--keyring", keyring });
        } else {
            try argv.appendSlice(sys.allocator, &.{ "--keyring", archive_keyring });
            if (sys.pathExists(role_keyring)) try argv.appendSlice(sys.allocator, &.{ "--keyring", role_keyring });
        }
        if (signature) |bytes| {
            const sig = try self.file("metadata.sig");
            try sys.write(sig, bytes, 0o600);
            try argv.appendSlice(sys.allocator, &.{ sig, input });
        } else try argv.appendSlice(sys.allocator, &.{ "--output", output, input });
        const result = try sys.capture(argv.items);
        if (!success(result.term) or std.mem.indexOf(u8, result.stdout, "[GNUPG:] VALIDSIG ") == null) return sys.fail("GPG signature verification failed (untrusted, invalid or expired signature): {s} {s}", .{ result.stderr, result.stdout });
        return if (signature != null) signed_data else sys.read(output, 16 << 20);
    }
};

pub const Digest = struct { sha256: [64]u8, size: u64 };

/// Read only the SHA256 section of a verified Debian Release. Do not accept
/// an MD5/SHA1 digest, duplicate entry, or a matching path in another section.
pub fn releaseDigest(text: []const u8, path: []const u8) !Digest {
    var active = false;
    var found: ?Digest = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.eql(u8, line, "SHA256:")) {
            active = true;
            continue;
        }
        if (line.len == 0 or (line[0] != ' ' and line[0] != '\t')) {
            active = false;
            continue;
        }
        if (!active) continue;
        var words = std.mem.tokenizeAny(u8, line, " \t");
        const hash = words.next() orelse continue;
        const size = words.next() orelse continue;
        const name = words.next() orelse continue;
        if (!std.mem.eql(u8, name, path)) continue;
        if (words.next() != null or hash.len != 64 or found != null) return error.InvalidReleaseDigest;
        var digest: Digest = .{ .sha256 = undefined, .size = try std.fmt.parseInt(u64, size, 10) };
        for (hash, 0..) |c, i| {
            if (!std.ascii.isHex(c)) return error.InvalidReleaseDigest;
            digest.sha256[i] = std.ascii.toLower(c);
        }
        found = digest;
    }
    return found orelse error.MissingReleaseDigest;
}

pub fn verifyBytes(data: []const u8, digest: Digest) !void {
    if (data.len != digest.size) return error.MetadataSizeMismatch;
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &actual, .{});
    const hex = std.fmt.bytesToHex(actual, .lower);
    if (!std.mem.eql(u8, &hex, &digest.sha256)) return error.MetadataChecksumMismatch;
}

pub fn codename(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, "Codename:")) return std.mem.trim(u8, line[9..], " \t\r");
    return null;
}

test "Release trust chain uses SHA256 and rejects mismatched metadata" {
    const hash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    const text = "Codename: trixie\nMD5Sum:\n 00000000000000000000000000000000 3 file\nSHA256:\n " ++ hash ++ " 3 file\nSHA512:\n ignored 3 file\n";
    const digest = try releaseDigest(text, "file");
    try verifyBytes("abc", digest);
    try std.testing.expectError(error.MetadataChecksumMismatch, verifyBytes("bad", digest));
    try std.testing.expectError(error.MetadataSizeMismatch, verifyBytes("abcx", digest));
    try std.testing.expectError(error.MissingReleaseDigest, releaseDigest(text, "absent"));
    try std.testing.expectError(error.InvalidReleaseDigest, releaseDigest("SHA256:\n " ++ hash ++ " 3 file\n " ++ hash ++ " 3 file\n", "file"));
    try std.testing.expectEqualStrings("trixie", codename(text).?);
}
