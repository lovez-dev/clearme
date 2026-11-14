const std = @import("std");

pub const Entry = struct {
    name: []const u8,
    mode: u32,
    data: []const u8 = "",
};

pub fn dir(name: []const u8, mode: u32) Entry {
    return .{ .name = name, .mode = mode | 0o040000 };
}

pub fn file(name: []const u8, mode: u32, data: []const u8) Entry {
    return .{ .name = name, .mode = mode | 0o100000, .data = data };
}

pub fn symlink(name: []const u8, target: []const u8) Entry {
    return .{ .name = name, .mode = 0o120777, .data = target };
}

pub fn write(allocator: std.mem.Allocator, entries: []const Entry) ![]u8 {
    var work = std.heap.ArenaAllocator.init(allocator);
    defer work.deinit();
    const scratch = work.allocator();
    var all: std.ArrayList(Entry) = .empty;
    defer all.deinit(allocator);
    var names: std.StringHashMap(void) = .init(scratch);
    defer names.deinit();
    for (entries) |entry| try names.put(std.mem.trimEnd(u8, entry.name, "/"), {});

    for (entries) |entry| {
        const normalized = std.mem.trim(u8, entry.name, "/");
        var parts = std.mem.splitScalar(u8, normalized, '/');
        var path: std.ArrayList(u8) = .empty;
        defer path.deinit(scratch);
        var part_index: usize = 0;
        while (parts.next()) |part| : (part_index += 1) {
            if (part_index > 0) try path.append(scratch, '/');
            try path.appendSlice(scratch, part);
            if (parts.peek() != null) {
                const parent = try scratch.dupe(u8, path.items);
                if (!names.contains(parent)) {
                    try names.put(parent, {});
                    try all.append(allocator, dir(parent, 0o755));
                }
            }
        }
    }
    try all.appendSlice(allocator, entries);
    stableSort(all.items);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var inode: u32 = 1;
    for (all.items) |entry| {
        try writeEntry(allocator, &output, entry, inode);
        inode += 1;
    }
    try writeEntry(allocator, &output, .{ .name = "TRAILER!!!", .mode = 0 }, 0);
    return output.toOwnedSlice(allocator);
}

fn stableSort(entries: []Entry) void {
    if (entries.len < 2) return;
    for (1..entries.len) |i| {
        const value = entries[i];
        var j = i;
        while (j > 0 and std.mem.lessThan(u8, value.name, entries[j - 1].name)) : (j -= 1) {
            entries[j] = entries[j - 1];
        }
        entries[j] = value;
    }
}

fn writeEntry(allocator: std.mem.Allocator, output: *std.ArrayList(u8), entry: Entry, inode: u32) !void {
    const size: usize = if (entry.mode & 0o040000 != 0) 0 else entry.data.len;
    const fields = [_]u32{
        inode,                        entry.mode, 0, 0, 1, 0, @intCast(size), 0, 0, 0, 0,
        @intCast(entry.name.len + 1), 0,
    };
    try output.appendSlice(allocator, "070701");
    for (fields) |field| try appendHex(allocator, output, field);
    try output.appendSlice(allocator, entry.name);
    try output.append(allocator, 0);
    try pad(allocator, output, 110 + entry.name.len + 1);
    if (size > 0) {
        try output.appendSlice(allocator, entry.data);
        try pad(allocator, output, size);
    }
}

fn appendHex(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: u32) !void {
    const digits = "0123456789ABCDEF";
    var shift: u5 = 28;
    while (true) {
        try output.append(allocator, digits[(value >> shift) & 0xf]);
        if (shift == 0) break;
        shift -= 4;
    }
}

fn pad(allocator: std.mem.Allocator, output: *std.ArrayList(u8), size: usize) !void {
    try output.appendNTimes(allocator, 0, (4 - size % 4) % 4);
}

test "newc writer adds parent directories and trailer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const data = try write(arena.allocator(), &.{
        file("preseed.cfg", 0o644, "hello"),
        file("clearme-assets/late.sh", 0o755, "#!/bin/sh\nexit 0\n"),
    });
    try std.testing.expect(std.mem.startsWith(u8, data, "070701"));
    try std.testing.expect(std.mem.indexOf(u8, data, "clearme-assets") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "preseed.cfg") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "TRAILER!!!") != null);
    try std.testing.expectEqual(@as(usize, 0), data.len % 4);
}
