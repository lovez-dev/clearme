const std = @import("std");
const System = @import("system.zig").System;

pub fn memoryMB(sys: *System) u64 {
    var lines = std.mem.splitScalar(u8, sys.readOptional("/proc/meminfo"), '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        if (!std.mem.eql(u8, fields.next() orelse "", "MemTotal:")) continue;
        return (std.fmt.parseInt(u64, fields.next() orelse "0", 10) catch 0) / 1024;
    }
    return 0;
}

fn container(sys: *System) []const u8 {
    for ([_][]const u8{ "/.dockerenv", "/run/.containerenv" }) |path| if (sys.pathExists(path)) return path;
    const cgroup = sys.readOptional("/proc/1/cgroup");
    for ([_][]const u8{ "docker", "lxc", "kubepods", "containerd" }) |marker| if (std.mem.indexOf(u8, cgroup, marker) != null) return marker;
    if (sys.pathExists("/proc/vz") and sys.pathExists("/proc/bc")) return "OpenVZ";
    const virt = sys.optional(&.{"systemd-detect-virt"});
    for ([_][]const u8{ "openvz", "lxc", "lxc-libvirt", "docker", "podman", "systemd-nspawn" }) |name| if (std.mem.eql(u8, virt, name)) return name;
    return "";
}

fn secureBoot(sys: *System) bool {
    var dir = std.Io.Dir.cwd().openDir(sys.io, "/sys/firmware/efi/efivars", .{ .iterate = true }) catch return false;
    defer dir.close(sys.io);
    var it = dir.iterate();
    while (it.next(sys.io) catch null) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "SecureBoot-")) continue;
        const data = dir.readFileAlloc(sys.io, entry.name, sys.allocator, .limited(1024)) catch continue;
        if (data.len > 4) return data[4] == 1;
    }
    return false;
}

pub fn check(sys: *System, force: bool) ![]const []const u8 {
    if (!sys.isRoot()) return sys.fail("Root privileges required", .{});
    var warnings: std.ArrayList([]const u8) = .empty;
    const container_name = container(sys);
    if (container_name.len > 0) {
        if (!force) return sys.fail("Running in container ({s}); cannot modify the bootloader", .{container_name});
        try warnings.append(sys.allocator, "Container detected (ignored with --force)");
    }
    const proc_version = try std.ascii.allocLowerString(sys.allocator, sys.readOptional("/proc/version"));
    if (std.mem.indexOf(u8, proc_version, "microsoft") != null) {
        if (!force) return sys.fail("WSL is not supported", .{});
        try warnings.append(sys.allocator, "WSL detected (ignored with --force)");
    }
    if (secureBoot(sys)) {
        if (!force) return sys.fail("Secure Boot is enabled and prevents the installer kernel from booting; disable Secure Boot first", .{});
        try warnings.append(sys.allocator, "Secure Boot enabled (ignored with --force)");
    }
    const mb = memoryMB(sys);
    if (mb > 0 and mb < 384) {
        if (!force) return sys.fail("Only {d} MB of memory detected; at least 384 MB required", .{mb});
        try warnings.append(sys.allocator, try std.fmt.allocPrint(sys.allocator, "Low memory: {d} MB", .{mb}));
    }
    var os_id: []const u8 = "";
    var lines = std.mem.splitScalar(u8, sys.readOptional("/etc/os-release"), '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, "ID=")) {
        os_id = std.mem.trim(u8, line[3..], "\"");
        break;
    };
    if (!std.mem.eql(u8, os_id, "debian")) try warnings.append(sys.allocator, try std.fmt.allocPrint(sys.allocator, "Source system is {s}, not Debian; continuing anyway", .{os_id}));
    return warnings.toOwnedSlice(sys.allocator);
}
