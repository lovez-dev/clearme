const std = @import("std");
const System = @import("system.zig").System;

pub const begin_marker = "### BEGIN clearme ###";
pub const end_marker = "### END clearme ###";
pub const menu_title = "Debian Installer (clearme)";
pub const menu_id = "clearme";
const custom_path = "/etc/grub.d/40_custom";
const saved_path = "/etc/default/grub.d/zz-clearme.cfg";

pub const Entry = struct {
    kernel_path: []const u8,
    initrd_path: []const u8,
    firmware: []const u8 = "",
    kernel_args: []const u8,
};

pub fn stripBlock(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, data, begin_marker) orelse return data;
    const relative_end = std.mem.indexOf(u8, data[start..], end_marker) orelse return data[0..start];
    var end = start + relative_end + end_marker.len;
    if (end < data.len and data[end] == '\n') end += 1;
    return std.mem.concat(allocator, u8, &.{ data[0..start], data[end..] });
}

pub fn install(sys: *System, entry: Entry) !void {
    if (!sys.pathExists(custom_path)) return sys.fail("{s} not found; this system may not use GRUB2", .{custom_path});
    try sys.mkdir("/etc/default/grub.d");
    try sys.write(saved_path, "# Added by clearme\nGRUB_DEFAULT=saved\nGRUB_TIMEOUT=5\nGRUB_TIMEOUT_STYLE=menu\n", 0o644);
    const block = try std.fmt.allocPrint(sys.allocator, "{s}\nmenuentry '{s}' --id {s} {{\n    insmod part_msdos\n    insmod part_gpt\n    insmod ext2\n    insmod xfs\n    insmod btrfs\n    linux {s} {s}\n    initrd {s} {s}\n}}\n{s}\n", .{ begin_marker, menu_title, menu_id, entry.kernel_path, entry.kernel_args, entry.initrd_path, entry.firmware, end_marker });
    const cleaned = try stripBlock(sys.allocator, try sys.read(custom_path, 4 << 20));
    try sys.write(custom_path, try std.mem.concat(sys.allocator, u8, &.{ cleaned, block }), 0o755);
    try update(sys);
}

pub fn reset(sys: *System) !void {
    if (!sys.isRoot()) return sys.fail("Root privileges required", .{});
    if (sys.read(custom_path, 4 << 20)) |data| try sys.write(custom_path, try stripBlock(sys.allocator, data), 0o755) else |_| {}
    sys.remove(saved_path);
    try std.Io.Dir.cwd().deleteTree(sys.io, "/boot/clearme");
    const tool = sys.firstCommand(&.{ "grub-editenv", "grub2-editenv" });
    if (tool.len > 0) for ([_][]const u8{ "/boot/grub/grubenv", "/boot/grub2/grubenv" }) |env| {
        if (sys.pathExists(env)) _ = sys.optional(&.{ tool, env, "unset", "next_entry" });
    };
    try update(sys);
}

pub fn installed(sys: *System) bool {
    return std.mem.indexOf(u8, sys.readOptional(custom_path), begin_marker) != null;
}

pub fn nextEntry(sys: *System) []const u8 {
    for ([_][]const u8{ "/boot/grub/grubenv", "/boot/grub2/grubenv" }) |env| {
        var lines = std.mem.splitScalar(u8, sys.readOptional(env), '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "#\r");
            if (std.mem.startsWith(u8, line, "next_entry=")) return line[11..];
        }
    }
    return "";
}

pub fn update(sys: *System) !void {
    const tools = [_][]const []const u8{
        &.{"update-grub"},
        &.{ "grub2-mkconfig", "-o", "/boot/grub2/grub.cfg" },
        &.{ "grub-mkconfig", "-o", "/boot/grub/grub.cfg" },
    };
    var attempted = false;
    for (tools) |argv| {
        if (!sys.commandExists(argv[0])) continue;
        attempted = true;
        _ = sys.run(argv) catch continue;
        return;
    }
    if (attempted) return error.Failed;
    return sys.fail("No GRUB configuration tool found (update-grub/grub2-mkconfig/grub-mkconfig)", .{});
}

pub fn setOneTimeBoot(sys: *System) !void {
    const tool = sys.firstCommand(&.{ "grub-reboot", "grub2-reboot" });
    if (tool.len == 0) return sys.fail("grub-reboot not found; reboot and select {s} manually", .{menu_title});
    _ = try sys.run(&.{ tool, menu_title });
}

pub fn relPath(sys: *System, path: []const u8) ![]const u8 {
    for ([_][]const u8{ "grub-mkrelpath", "grub2-mkrelpath" }) |name| {
        const out = sys.optional(&.{ name, path });
        if (std.mem.startsWith(u8, out, "/")) return out;
    }
    const boot_dev = sys.optional(&.{ "findmnt", "-n", "-o", "SOURCE", "/boot" });
    const root_dev = sys.optional(&.{ "findmnt", "-n", "-o", "SOURCE", "/" });
    if (boot_dev.len > 0 and !std.mem.eql(u8, boot_dev, root_dev) and std.mem.startsWith(u8, path, "/boot/")) return path[5..];
    return path;
}

test "GRUB block replacement preserves unrelated configuration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("before\nafter\n", try stripBlock(a, "before\n" ++ begin_marker ++ "\nold\n" ++ end_marker ++ "\nafter\n"));
    try std.testing.expectEqualStrings("before\n", try stripBlock(a, "before\n" ++ begin_marker ++ "\ntruncated"));
}
