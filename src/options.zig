//! Parsed command-line configuration (port of Go `app.Options`).
//! String fields either point at static defaults or borrow from the arena
//! passed to `cli.parse`; the process arena outlives every use, so this
//! struct needs no deinit.

pub const Options = struct {
    // mirror and target suite
    suite: []const u8 = "",
    mirror: []const u8 = "",
    china: bool = false,
    proxy: []const u8 = "",

    // network
    ip: []const u8 = "",
    netmask: []const u8 = "",
    gateway: []const u8 = "",
    dns: []const u8 = "1.1.1.1 8.8.8.8",
    dns_explicit: bool = false,
    ipv6: []const u8 = "",
    ipv6_gateway: []const u8 = "",
    ipv6_dns: []const u8 = "",
    hostname: []const u8 = "",
    interface: []const u8 = "auto",

    // account / ssh
    user: []const u8 = "root",
    password: []const u8 = "",
    ssh_port: u16 = 22,
    authorized_keys_url: []const u8 = "",

    // disk
    disk: []const u8 = "",
    filesystem: []const u8 = "ext4",
    btrfs_compress: []const u8 = "",
    keep_data: bool = false,
    keep_parts: []const []const u8 = &.{},
    boot_mode: []const u8 = "auto",
    esp_size: u16 = 106,
    system_size: []const u8 = "",
    system_size_mb: u32 = 0,

    // install
    install: []const u8 = "ca-certificates sudo curl wget net-tools unzip",
    upgrade: []const u8 = "full",
    post_install: []const u8 = "",
    apt_repos: []const []const u8 = &.{},
    fail2ban: bool = false,
    firmware: bool = false,
    swap_size: []const u8 = "",
    swap_mb: u32 = 0,
    swap: bool = false,
    optimize: bool = true,
    unattended: bool = true,
    installer_ssh: bool = true,
    timezone: []const u8 = "Asia/Shanghai",
    ntp: []const u8 = "time.cloudflare.com",
    ntp_explicit: bool = false,
    kernel: []const u8 = "",
    cloud_kernel: bool = false,
    bpo_kernel: bool = false,
    cidata: []const u8 = "",
    verify_signatures: bool = true,
    keyring: []const u8 = "",
    hold: u16 = 0,
    force_lowmem: []const u8 = "",
    allow_unverified: bool = false,
    log_file: []const u8 = "/var/log/clearme.log",

    // run control
    program_version: bool = false,
    dry_run: bool = false,
    reboot: bool = false,
    yes: bool = false,
    force: bool = false,
};

const std = @import("std");

test "defaults match the Go version" {
    const o: Options = .{};
    try std.testing.expectEqualStrings("root", o.user);
    try std.testing.expectEqual(@as(u16, 22), o.ssh_port);
    try std.testing.expectEqualStrings("ext4", o.filesystem);
    try std.testing.expectEqualStrings("Asia/Shanghai", o.timezone);
    try std.testing.expect(o.optimize);
    try std.testing.expect(o.unattended);
    try std.testing.expect(o.installer_ssh);
    try std.testing.expectEqualStrings("full", o.upgrade);
}
