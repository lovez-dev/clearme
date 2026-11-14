const std = @import("std");
const assets = @import("assets.zig");
const template = @import("template.zig");
const cpio = @import("cpio.zig");

pub const FstabEntry = struct {
    PartUUID: []const u8,
    MountPoint: []const u8,
    FSType: []const u8,
    Pass: u8,
};

// Field names also form the embedded templates' interface.
pub const Config = struct {
    Interface: []const u8 = "",
    Static: bool = false,
    IP: []const u8 = "",
    Netmask: []const u8 = "",
    Gateway: []const u8 = "",
    DNS: []const u8 = "",
    Hostname: []const u8 = "",
    Interfaces: []const u8 = "",
    ResolvConf: []const u8 = "",
    MirrorProtocol: []const u8 = "https",
    MirrorHost: []const u8 = "deb.debian.org",
    MirrorDir: []const u8 = "/debian",
    Suite: []const u8 = "trixie",
    SecurityRepo: []const u8 = "",
    SecuritySuite: []const u8 = "",
    Timezone: []const u8 = "Asia/Shanghai",
    NTP: []const u8 = "",
    Disk: []const u8 = "",
    DiskLabel: []const u8 = "gpt",
    EFI: bool = false,
    ESPSize: u32 = 106,
    SystemSize: []const u8 = "",
    SystemSizeMB: u32 = 0,
    Filesystem: []const u8 = "ext4",
    BtrfsCompress: []const u8 = "",
    KeepParts: []const u32 = &.{},
    Arch: []const u8 = "amd64",
    NonFreeFirmware: bool = true,
    Username: []const u8 = "root",
    PasswordHash: []const u8 = "",
    Install: []const u8 = "",
    Upgrade: []const u8 = "",
    SSHPort: u16 = 22,
    AuthorizedKeys: []const u8 = "",
    KeepFstab: []const FstabEntry = &.{},
    Optimize: bool = false,
    Swap: bool = false,
    SwapSize: []const u8 = "",
    SwapMB: u32 = 0,
    Packages: []const u8 = "",
    PostInstall: []const u8 = "",
    ExtraRepos: []const []const u8 = &.{},
    Unattended: bool = false,
    Fail2ban: bool = false,
    Proxy: []const u8 = "",
    InstallerSSH: bool = false,
    Home: []const u8 = "",
    KeysB64: []const u8 = "",
    PostInstallB64: []const u8 = "",
    Kernel: []const u8 = "",
    HoldBefore: bool = false,
    HoldAfter: bool = false,
    InstallerOnlink: bool = false,
    IPPrefix: u8 = 24,
    InstallerV6Address: []const u8 = "",
    InstallerV6Interface: []const u8 = "",
    InstallerV6Prefix: u8 = 64,
    InstallerV6Gateway: []const u8 = "",
    BackportsSuite: []const u8 = "",
    CloudInit: bool = false,
    CloudNetwork: bool = false,
    CloudSeed: @import("cloudinit.zig").Seed = .{},
};

fn b64(arena: std.mem.Allocator, data: []const u8) ![]const u8 {
    const encoder = std.base64.standard.Encoder;
    return encoder.encode(try arena.alloc(u8, encoder.calcSize(data.len)), data);
}

pub fn preseed(arena: std.mem.Allocator, config: Config) ![]const u8 {
    return template.render(arena, assets.preseed, config);
}

pub fn renderFirstboot(arena: std.mem.Allocator, config: Config) ![]const u8 {
    var cfg = config;
    if (std.mem.trim(u8, cfg.PostInstall, " \t\r\n").len > 0) cfg.PostInstallB64 = try b64(arena, cfg.PostInstall);
    if (cfg.SwapSize.len == 0) cfg.SwapSize = "1G";
    if (cfg.SwapMB == 0) cfg.SwapMB = 1024;
    return template.render(arena, assets.firstboot, cfg);
}

pub fn renderLate(arena: std.mem.Allocator, config: Config) ![]const u8 {
    var cfg = config;
    cfg.Home = if (std.mem.eql(u8, cfg.Username, "root")) "/root" else try std.fmt.allocPrint(arena, "/home/{s}", .{cfg.Username});
    cfg.KeysB64 = try b64(arena, cfg.AuthorizedKeys);
    return template.render(arena, assets.late, cfg);
}

pub fn build(arena: std.mem.Allocator, cfg: Config) ![]cpio.Entry {
    var entries: std.ArrayList(cpio.Entry) = .empty;
    try entries.appendSlice(arena, &.{
        cpio.file("preseed.cfg", 0o644, try preseed(arena, cfg)),
        cpio.file("clearme-assets/late.sh", 0o755, try renderLate(arena, cfg)),
        cpio.file("clearme-assets/firstboot.sh", 0o755, try renderFirstboot(arena, cfg)),
        cpio.file("clearme-assets/fix-eth-name.sh", 0o755, assets.fix_eth_name),
        cpio.file("clearme-assets/fix-eth-name.service", 0o644, assets.fix_eth_name_service),
        cpio.file("clearme-assets/early.sh", 0o755, try template.render(arena, assets.early, cfg)),
    });
    if (cfg.InstallerOnlink) try entries.append(arena, cpio.file("var/lib/dpkg/info/netcfg.postinst", 0o755, try template.render(arena, assets.netcfg_onlink, cfg)));
    if (cfg.SystemSizeMB > 0) try entries.append(arena, cpio.file("clearme-assets/system-size", 0o600, ""));
    if (cfg.HoldBefore or cfg.HoldAfter) try entries.append(arena, cpio.file("clearme-assets/wait.sh", 0o755, assets.wait));
    if (cfg.HoldBefore) try entries.append(arena, cpio.file("clearme-assets/hold-before", 0o600, ""));
    if (cfg.CloudInit) {
        try entries.appendSlice(arena, &.{
            cpio.file("clearme-assets/cloud-init/meta-data", 0o600, cfg.CloudSeed.meta_data),
            cpio.file("clearme-assets/cloud-init/user-data", 0o600, cfg.CloudSeed.user_data),
        });
        if (cfg.CloudSeed.has_vendor) try entries.append(arena, cpio.file("clearme-assets/cloud-init/vendor-data", 0o600, cfg.CloudSeed.vendor_data));
        if (cfg.CloudSeed.has_network) try entries.append(arena, cpio.file("clearme-assets/cloud-init/network-config", 0o600, cfg.CloudSeed.network_config));
    }
    if (cfg.SecurityRepo.len > 0) try entries.append(arena, cpio.file("clearme-assets/post-base-installer.sh", 0o755, try template.render(arena, assets.post_base_installer, cfg)));
    if (cfg.Optimize) inline for (assets.optimize) |asset| {
        try entries.append(arena, cpio.file("clearme-assets/optimize/" ++ asset[0], 0o755, asset[1]));
    };
    if (cfg.Upgrade.len > 0) try entries.append(arena, cpio.file("clearme-assets/cleanup.sh", 0o755, assets.cleanup));
    try entries.append(arena, cpio.file("clearme-assets/partman-early.sh", 0o755, assets.partman_early));
    if (cfg.InstallerSSH) {
        try entries.append(arena, cpio.file("clearme-assets/installer-ssh.sh", 0o755, try template.render(arena, assets.installer_ssh, cfg)));
        try entries.append(arena, cpio.file("configs/clearme-installer-pass", 0o600, try std.fmt.allocPrint(arena, "{s}\n", .{cfg.PasswordHash})));
        if (cfg.AuthorizedKeys.len > 0) try entries.append(arena, cpio.file("configs/clearme-installer-keys", 0o600, cfg.AuthorizedKeys));
    }
    return entries.toOwnedSlice(arena);
}

test "unchanged payload assets and archive metadata match Go references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{ "efi-root", "bios-keep", "minimal" }) |variant| {
        const parsed = try std.json.parseFromSlice(Config, a, @embedFile("testdata/payload/" ++ variant ++ ".json"), .{});
        const actual = try archiveEntries(a, try cpio.write(a, try build(a, parsed.value)));
        const reference = try archiveEntries(a, @embedFile("testdata/payload/" ++ variant ++ ".cpio"));
        try std.testing.expectEqual(reference.count(), actual.count());
        var it = reference.iterator();
        while (it.next()) |entry| {
            const current = actual.get(entry.key_ptr.*) orelse return error.MissingReferenceAsset;
            try std.testing.expectEqual(entry.value_ptr.mode, current.mode);
            // These scripts intentionally evolve beyond the Go migration.
            const changed = std.mem.eql(u8, entry.key_ptr.*, "preseed.cfg") or
                std.mem.eql(u8, entry.key_ptr.*, "clearme-assets/late.sh") or
                std.mem.eql(u8, entry.key_ptr.*, "clearme-assets/firstboot.sh") or
                std.mem.eql(u8, entry.key_ptr.*, "clearme-assets/cleanup.sh") or
                std.mem.eql(u8, entry.key_ptr.*, "clearme-assets/fix-eth-name.sh") or
                std.mem.eql(u8, entry.key_ptr.*, "clearme-assets/fix-eth-name.service") or
                std.mem.eql(u8, entry.key_ptr.*, "clearme-assets/early.sh") or
                std.mem.eql(u8, entry.key_ptr.*, "clearme-assets/post-base-installer.sh") or
                std.mem.eql(u8, entry.key_ptr.*, "clearme-assets/partman-early.sh") or
                std.mem.eql(u8, entry.key_ptr.*, "clearme-assets/installer-ssh.sh") or
                std.mem.startsWith(u8, entry.key_ptr.*, "clearme-assets/optimize/");
            if (!changed) try std.testing.expectEqualSlices(u8, entry.value_ptr.data, current.data);
        }
    }
}

fn archiveEntries(a: std.mem.Allocator, archive: []const u8) !std.StringHashMap(cpio.Entry) {
    var result = std.StringHashMap(cpio.Entry).init(a);
    var pos: usize = 0;
    while (pos + 110 <= archive.len) {
        const header = archive[pos..][0..110];
        if (!std.mem.eql(u8, header[0..6], "070701")) return error.InvalidCpio;
        const mode = try std.fmt.parseInt(u32, header[14..22], 16);
        const size = try std.fmt.parseInt(usize, header[54..62], 16);
        const namesize = try std.fmt.parseInt(usize, header[94..102], 16);
        pos += 110;
        const name = archive[pos..][0 .. namesize - 1];
        pos = std.mem.alignForward(usize, pos + namesize, 4);
        const data = archive[pos..][0..size];
        pos = std.mem.alignForward(usize, pos + size, 4);
        if (std.mem.eql(u8, name, "TRAILER!!!")) return result;
        try result.put(name, .{ .name = name, .mode = mode, .data = data });
    }
    return error.InvalidCpio;
}

test "installer onlink and hold configuration reaches the archive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config: Config = .{ .Interface = "ens3", .IP = "192.0.2.10", .IPPrefix = 32, .Gateway = "198.51.100.1", .InstallerOnlink = true, .HoldBefore = true, .InstallerSSH = true, .Kernel = "linux-image-cloud-amd64", .EFI = true, .ESPSize = 538 };
    const entries = try archiveEntries(a, try cpio.write(a, try build(a, config)));
    const netcfg = entries.get("var/lib/dpkg/info/netcfg.postinst").?.data;
    try std.testing.expect(std.mem.indexOf(u8, netcfg, "192.0.2.10/32") != null);
    try std.testing.expect(std.mem.indexOf(u8, netcfg, "default via '198.51.100.1' dev 'ens3' onlink") != null);
    try std.testing.expect(entries.contains("clearme-assets/hold-before"));
    try std.testing.expect(entries.contains("clearme-assets/wait.sh"));
    const seed = entries.get("preseed.cfg").?.data;
    try std.testing.expect(std.mem.indexOf(u8, seed, "linux-image-cloud-amd64") != null);
    try std.testing.expect(std.mem.indexOf(u8, seed, "538 538 538 free") != null);
    var after = config;
    after.HoldBefore = false;
    after.HoldAfter = true;
    const late = try renderLate(a, after);
    try std.testing.expect(std.mem.indexOf(u8, late, "sh \"$ASSETS/wait.sh\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, late, "halt") == null);
}

test "system size caps the root partition recipe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config: Config = .{ .Disk = "/dev/vda", .SystemSize = "10G", .SystemSizeMB = 10240 };
    const seed = try preseed(a, config);
    try std.testing.expect(std.mem.indexOf(u8, seed, "10240 10240 10240 $default_filesystem") != null);
    try std.testing.expect(std.mem.indexOf(u8, seed, "1075 4096 -1 $default_filesystem") == null);
    const archive = try build(a, config);
    var marker = false;
    for (archive) |entry| {
        if (std.mem.eql(u8, entry.name, "clearme-assets/system-size")) marker = true;
    }
    try std.testing.expect(marker);
}

test "executable payload scripts preserve their interpreter directives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const entries = try build(arena.allocator(), .{ .Optimize = true, .Upgrade = "full-upgrade", .InstallerSSH = true, .HoldBefore = true, .HoldAfter = true, .SecurityRepo = "https://deb.debian.org/debian-security" });
    for (entries) |entry| {
        if (entry.mode & 0o111 != 0) try std.testing.expect(std.mem.startsWith(u8, entry.data, "#!/bin/"));
    }
}
