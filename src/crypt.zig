const std = @import("std");

const alphabet = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const digest_order = [_]usize{
    0,  21, 42, 22, 43, 1,  44, 2,  23, 3,  24, 45, 25, 46, 4,  47, 5,  26,
    6,  27, 48, 28, 49, 7,  50, 8,  29, 9,  30, 51, 31, 52, 10, 53, 11, 32,
    12, 33, 54, 34, 55, 13, 56, 14, 35, 15, 36, 57, 37, 58, 16, 59, 17, 38,
    18, 39, 60, 40, 61, 19, 62, 20, 41,
};

pub fn sha512Crypt(allocator: std.mem.Allocator, password: []const u8, raw_salt: []const u8) ![]const u8 {
    const salt = raw_salt[0..@min(raw_salt.len, 16)];
    var b_hasher = std.crypto.hash.sha2.Sha512.init(.{});
    b_hasher.update(password);
    b_hasher.update(salt);
    b_hasher.update(password);
    var b: [64]u8 = undefined;
    b_hasher.final(&b);

    var a_hasher = std.crypto.hash.sha2.Sha512.init(.{});
    a_hasher.update(password);
    a_hasher.update(salt);
    updateRepeated(&a_hasher, &b, password.len);
    var count = password.len;
    while (count > 0) : (count >>= 1) {
        if (count & 1 != 0) a_hasher.update(&b) else a_hasher.update(password);
    }
    var current: [64]u8 = undefined;
    a_hasher.final(&current);

    var p_hasher = std.crypto.hash.sha2.Sha512.init(.{});
    for (0..password.len) |_| p_hasher.update(password);
    var p_digest: [64]u8 = undefined;
    p_hasher.final(&p_digest);
    const p = try repeatAlloc(allocator, &p_digest, password.len);
    defer allocator.free(p);

    var s_hasher = std.crypto.hash.sha2.Sha512.init(.{});
    for (0..(@as(usize, 16) + current[0])) |_| s_hasher.update(salt);
    var s_digest: [64]u8 = undefined;
    s_hasher.final(&s_digest);
    const s = try repeatAlloc(allocator, &s_digest, salt.len);
    defer allocator.free(s);

    for (0..5000) |round| {
        var h = std.crypto.hash.sha2.Sha512.init(.{});
        if (round & 1 != 0) h.update(p) else h.update(&current);
        if (round % 3 != 0) h.update(s);
        if (round % 7 != 0) h.update(p);
        if (round & 1 != 0) h.update(&current) else h.update(p);
        h.final(&current);
    }
    const encoded = try encode64(allocator, &current);
    defer allocator.free(encoded);
    return try std.fmt.allocPrint(allocator, "$6${s}${s}", .{ salt, encoded });
}

pub fn randomSalt(io: std.Io) [16]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    for (&bytes) |*byte| byte.* = alphabet[byte.* % alphabet.len];
    return bytes;
}

pub fn randomPassword(io: std.Io, allocator: std.mem.Allocator, len: usize) ![]u8 {
    const chars = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    const out = try allocator.alloc(u8, len);
    io.random(out);
    for (out) |*byte| byte.* = chars[byte.* % chars.len];
    return out;
}

fn updateRepeated(hasher: *std.crypto.hash.sha2.Sha512, bytes: []const u8, len: usize) void {
    var remaining = len;
    while (remaining > 0) {
        const n = @min(remaining, bytes.len);
        hasher.update(bytes[0..n]);
        remaining -= n;
    }
}

fn repeatAlloc(allocator: std.mem.Allocator, source: []const u8, len: usize) ![]u8 {
    const out = try allocator.alloc(u8, len);
    var offset: usize = 0;
    while (offset < len) {
        const n = @min(len - offset, source.len);
        @memcpy(out[offset .. offset + n], source[0..n]);
        offset += n;
    }
    return out;
}

fn encode64(allocator: std.mem.Allocator, digest: *const [64]u8) ![]u8 {
    const out = try allocator.alloc(u8, 86);
    var pos: usize = 0;
    var i: usize = 0;
    while (i + 2 < digest_order.len) : (i += 3) {
        var value = @as(u32, digest[digest_order[i]]) << 16 |
            @as(u32, digest[digest_order[i + 1]]) << 8 |
            @as(u32, digest[digest_order[i + 2]]);
        for (0..4) |_| {
            out[pos] = alphabet[value & 0x3f];
            pos += 1;
            value >>= 6;
        }
    }
    out[pos] = alphabet[digest[63] & 0x3f];
    out[pos + 1] = alphabet[(digest[63] >> 6) & 0x3f];
    return out;
}

test "SHA512 crypt matches standard vectors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1",
        try sha512Crypt(arena.allocator(), "Hello world!", "saltstring"),
    );
    try std.testing.expectEqualStrings(
        "$6$toolongsaltstrin$lQ8jolhgVRVhY4b5pZKaysCLi0QBxGoNeKQzQ3glMhwllF7oGDZxUhx1yxdYcz/e1JSbq3y6JMxxl8audkUEm0",
        try sha512Crypt(arena.allocator(), "This is just a test", "toolongsaltstring"),
    );
}
