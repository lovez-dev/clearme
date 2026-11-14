const std = @import("std");
const System = @import("system.zig").System;

pub const Part = struct {
    name: []const u8 = "",
    path: []const u8 = "",
    num: u32 = 0,
    size: []const u8 = "",
    fs_type: []const u8 = "",
    mountpoint: []const u8 = "",
    part_uuid: []const u8 = "",
};

pub fn parsePairs(allocator: std.mem.Allocator, line: []const u8) !std.StringHashMap([]const u8) {
    var result = std.StringHashMap([]const u8).init(allocator);
    var i: usize = 0;
    while (i < line.len) {
        while (i < line.len and line[i] == ' ') : (i += 1) {}
        const start = i;
        while (i < line.len and line[i] != '=') : (i += 1) {}
        if (i + 1 >= line.len or line[i + 1] != '"') break;
        const key = line[start..i];
        i += 2;
        const val_start = i;
        while (i < line.len and line[i] != '"') : (i += 1) {}
        try result.put(key, line[val_start..i]);
        if (i < line.len) i += 1;
    }
    return result;
}

pub fn list(sys: *System, disk: []const u8) ![]Part {
    const out = try sys.output(&.{ "lsblk", "-P", "-p", "-o", "NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT,PARTUUID", disk });
    var parts: std.ArrayList(Part) = .empty;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        const fields = try parsePairs(sys.allocator, line);
        if (!std.mem.eql(u8, fields.get("TYPE") orelse "", "part")) continue;
        const path = fields.get("NAME") orelse "";
        const num = partNum(path);
        if (num == 0) continue;
        try parts.append(sys.allocator, .{
            .name = if (std.mem.startsWith(u8, path, "/dev/")) path[5..] else path,
            .path = path,
            .num = num,
            .size = fields.get("SIZE") orelse "",
            .fs_type = fields.get("FSTYPE") orelse "",
            .mountpoint = fields.get("MOUNTPOINT") orelse "",
            .part_uuid = fields.get("PARTUUID") orelse "",
        });
    }
    return parts.toOwnedSlice(sys.allocator);
}

pub fn partNum(name: []const u8) u32 {
    var i = name.len;
    while (i > 0 and std.ascii.isDigit(name[i - 1])) : (i -= 1) {}
    return std.fmt.parseInt(u32, name[i..], 10) catch 0;
}

pub fn isMountable(fs_type: []const u8) bool {
    for ([_][]const u8{ "ext2", "ext3", "ext4", "xfs", "btrfs" }) |fs| if (std.mem.eql(u8, fs_type, fs)) return true;
    return false;
}

fn systemMount(path: []const u8) bool {
    for ([_][]const u8{ "/", "/boot", "/boot/efi", "/usr", "/var", "/etc", "/tmp" }) |mount| if (std.mem.eql(u8, path, mount)) return true;
    return false;
}

pub fn analyze(sys: *System, disk: []const u8, root_path: []const u8, explicit: []const []const u8) ![]Part {
    return select(sys, try list(sys, disk), disk, root_path, explicit);
}

pub fn select(sys: *System, parts: []const Part, disk: []const u8, root_path: []const u8, explicit: []const []const u8) ![]Part {
    var keep: std.ArrayList(Part) = .empty;
    if (explicit.len > 0) {
        for (explicit) |path| {
            var found = false;
            for (parts) |p| {
                if (!std.mem.eql(u8, p.path, path)) continue;
                if (std.mem.eql(u8, p.path, root_path)) return sys.fail("Cannot preserve root partition {s}", .{path});
                if (std.mem.eql(u8, p.fs_type, "swap")) return sys.fail("Cannot preserve swap partition {s}", .{path});
                if (systemMount(p.mountpoint)) return sys.fail("Cannot preserve {s}: mounted at system path {s}", .{ path, p.mountpoint });
                if (p.fs_type.len == 0) return sys.fail("Cannot preserve {s}: unknown filesystem", .{path});
                try keep.append(sys.allocator, p);
                found = true;
                break;
            }
            if (!found) return sys.fail("Partition {s} does not belong to {s}", .{ path, disk });
        }
        return keep.toOwnedSlice(sys.allocator);
    }
    for (parts) |p| {
        if (std.mem.eql(u8, p.path, root_path) or systemMount(p.mountpoint) or !isMountable(p.fs_type)) continue;
        try keep.append(sys.allocator, p);
    }
    if (keep.items.len == 0) return sys.fail("--keep-data: no data partition found on {s}; specify --keep-part", .{disk});
    if (keep.items.len > 1) return sys.fail("--keep-data: multiple candidate partitions found; select with --keep-part", .{});
    return keep.toOwnedSlice(sys.allocator);
}

pub fn mountPointFor(allocator: std.mem.Allocator, index: usize) ![]const u8 {
    return if (index == 0) "/data" else std.fmt.allocPrint(allocator, "/data{d}", .{index + 1});
}

pub fn fstabPass(fs_type: []const u8) u8 {
    return if (std.mem.eql(u8, fs_type, "btrfs")) 0 else 2;
}

test "partition selection rejects system mounts and ambiguous disks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sys: System = .{ .io = std.testing.io, .allocator = arena.allocator() };
    const parts = [_]Part{
        .{ .path = "/dev/sda1", .fs_type = "ext4", .mountpoint = "/", .num = 1 },
        .{ .path = "/dev/sda2", .fs_type = "ext4", .mountpoint = "/data", .num = 2 },
    };
    const kept = try select(&sys, &parts, "/dev/sda", "/dev/sda1", &.{});
    try std.testing.expectEqual(@as(u32, 2), kept[0].num);
    try std.testing.expectError(error.Failed, select(&sys, &parts, "/dev/sda", "/dev/sda1", &.{"/dev/sda1"}));
    try std.testing.expectEqual(@as(u32, 12), partNum("/dev/nvme0n1p12"));
    try std.testing.expectEqual(@as(u32, 0), partNum("/dev/sda"));
    const fields = try parsePairs(sys.allocator, "NAME=\"/dev/sda2\" FSTYPE=\"ext4\" MOUNTPOINT=\"/data files\"");
    try std.testing.expectEqualStrings("/data files", fields.get("MOUNTPOINT").?);
}
