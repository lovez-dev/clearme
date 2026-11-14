//! Read only the documented NoCloud seed files; never archive an entire directory.
const std = @import("std");
const System = @import("system.zig").System;

pub const Seed = struct {
    meta_data: []const u8 = "",
    user_data: []const u8 = "",
    vendor_data: []const u8 = "",
    network_config: []const u8 = "",
    has_vendor: bool = false,
    has_network: bool = false,
};

pub fn load(sys: *System, path: []const u8) !Seed {
    var dir = std.Io.Dir.cwd().openDir(sys.io, path, .{}) catch return sys.fail("Cannot open cloud-init directory: {s}", .{path});
    defer dir.close(sys.io);
    var seed: Seed = .{};
    seed.meta_data = try readRequired(sys, &dir, "meta-data");
    seed.user_data = try readRequired(sys, &dir, "user-data");
    seed.vendor_data = readOptional(sys, &dir, "vendor-data") catch "";
    seed.has_vendor = seed.vendor_data.len > 0;
    seed.network_config = readOptional(sys, &dir, "network-config") catch "";
    seed.has_network = seed.network_config.len > 0;
    return seed;
}

fn readRequired(sys: *System, dir: *std.Io.Dir, name: []const u8) ![]const u8 {
    return readFile(sys, dir, name) catch return sys.fail("cloud-init file missing or unreadable: {s}", .{name});
}

fn readOptional(sys: *System, dir: *std.Io.Dir, name: []const u8) ![]const u8 {
    return readFile(sys, dir, name);
}

fn readFile(sys: *System, dir: *std.Io.Dir, name: []const u8) ![]const u8 {
    const s = dir.statFile(sys.io, name, .{ .follow_symlinks = false }) catch |err| return err;
    if (s.kind != .file) return error.NotAFile;
    if (s.size > 1 << 20) return error.FileTooBig;
    const file = try dir.openFile(sys.io, name, .{ .follow_symlinks = false });
    defer file.close(sys.io);
    var reader = file.reader(sys.io, &.{});
    return reader.interface.allocRemaining(sys.allocator, .limited(1 << 20));
}
