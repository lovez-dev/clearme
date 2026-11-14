//! Full Chinese help text, a line-by-line port of Go `cli.Usage`.
//! Colors follow fatih/color semantics: applied only when the stream is a
//! TTY and NO_COLOR is unset (CLICOLOR_FORCE forces them on).
const std = @import("std");
const version = @import("version.zig").version;

pub fn print(out: *std.Io.Writer, color: bool) !void {
    if (color) {
        try out.print("\x1b[1;36mclearme\x1b[0m \x1b[2m{s}\x1b[0m  \x1b[1mDebian network reinstall tool\x1b[0m\n", .{version});
    } else {
        try out.print("clearme {s}  Debian network reinstall tool\n", .{version});
    }

    try section(out, color, "Usage");
    try option(out, color, "clearme [options]", "Prepare reinstallation; boot the installer on the next restart");
    try option(out, color, "clearme status", "Show installer files, GRUB entry and log status");
    try option(out, color, "clearme logs [type]", "Show logs: clearme, firstboot, cleanup or all");
    try option(out, color, "clearme reset", "Remove the installer boot entry and downloaded files");
    try option(out, color, "clearme -V", "Show program version (--version selects the Debian release)");

    try section(out, color, "Target and mirrors");
    try option(out, color, "--version VERSION", "Release: 11/12/13/14/sid or codename (default: stable)");
    try option(out, color, "--mirror URL", "Full mirror URL (default: deb.debian.org)");
    try option(out, color, "--china", "Select a Chinese mirror using speed tests");
    try option(out, color, "--proxy URL", "Proxy for downloads and target system APT");

    try section(out, color, "Network");
    try option(out, color, "--ip ADDR", "Static IPv4 address (default: preserve current DHCP/static mode)");
    try option(out, color, "--netmask MASK", "Subnet mask, e.g. 255.255.255.0");
    try option(out, color, "--gateway ADDR", "Default gateway");
    try option(out, color, "--ipv6 ADDR[/PREFIX]", "Static IPv6 address (gateway defaults to current RA)");
    try option(out, color, "--ipv6-gateway ADDR", "IPv6 gateway (default: current RA/DHCPv6)");
    try option(out, color, "--ipv6-dns \"ADDR ...\"", "IPv6 DNS servers (space-separated)");
    try option(out, color, "--dns \"SERVERS\"", "DNS servers (default: current system)");
    try option(out, color, "--hostname NAME", "Hostname (default: current hostname)");
    try option(out, color, "--interface NAME", "Network interface (default: auto, follows the default route)");

    try section(out, color, "Accounts and SSH");
    try option(out, color, "--user NAME", "Login user (default: root)");
    try option(out, color, "--password PASS", "Login password; generated and displayed if omitted");
    try option(out, color, "--ssh-port N", "SSH port (default: 22; also used during installation)");
    try option(out, color, "--authorized-keys-url URL", "Install SSH public keys on first boot and disable password authentication");

    try section(out, color, "Disks and boot");
    try option(out, color, "--disk /dev/sdX", "Target disk (default: disk containing the root partition)");
    try option(out, color, "--filesystem FS", "Root filesystem: ext4/xfs/btrfs (default: ext4)");
    try option(out, color, "--btrfs-compress ALGO", "Btrfs compression, e.g. zstd:3 (requires --filesystem btrfs)");
    try option(out, color, "--boot-mode auto|bios|efi", "Target boot mode (default: auto; does not change firmware settings)");
    try option(out, color, "--esp MB", "EFI system partition size in MB (minimum/default: 106)");
    try option(out, color, "--system-size SIZE", "Root partition size, e.g. 10G; leave remaining space unallocated (default: all available space)");
    try option(out, color, "--keep-data", "Preserve an automatically detected data partition");
    try option(out, color, "--keep-part /dev/sdX3", "Partition to preserve (repeatable)");

    try section(out, color, "System and initialization");
    try option(out, color, "--install \"PKG ...\"", "Additional packages (space-separated)");
    try option(out, color, "--upgrade none|safe|full", "APT upgrade during installation (default: full)");
    try option(out, color, "--post-install PATH|URL", "Script to execute on first boot (local file or URL)");
    try option(out, color, "--apt-repo 'deb ...'", "Additional APT source (repeatable)");
    try option(out, color, "--fail2ban", "Install fail2ban and enable SSH brute force protection");
    try option(out, color, "--firmware", "Include non-free firmware (physical machines only; prohibited on VMs)");
    try option(out, color, "--swap-size SIZE", "Create a swapfile, e.g. 512M, 2G, 2048MB (default: based on RAM)");
    try option(out, color, "--timezone ZONE", "Time zone (default: Asia/Shanghai)");
    try option(out, color, "--ntp HOST", "NTP server (explicit value overrides --china preset)");
    try option(out, color, "--kernel PACKAGE", "Kernel package (default: linux-image-ARCH)");
    try option(out, color, "--cloud-kernel", "Use a cloud kernel (cannot combine with --kernel)");
    try option(out, color, "--bpo-kernel", "Use a Debian backports kernel (Debian 12/13)");
    try option(out, color, "--cidata DIR", "Use a local cloud-init NoCloud seed directory");
    try option(out, color, "--force-lowmem 0|1|2", "Set the Debian installer low memory mode");
    try option(out, color, "--optimize=false", "Disable first boot system tuning (enabled by default)");
    try option(out, color, "--unattended=false", "Disable automatic security updates (enabled by default)");
    try option(out, color, "--installer-ssh=false", "Disable installer SSH (enabled by default; required by hold mode)");

    try section(out, color, "Execution");
    try option(out, color, "--dry-run", "Print a configuration summary without changing the system");
    try option(out, color, "--yes", "Skip confirmation");
    try option(out, color, "--reboot-now", "Reboot immediately after preparation");
    try option(out, color, "--force", "Override container, Secure Boot and low memory checks");
    try option(out, color, "--hold 0|1|2", "1: pause before partitioning; 2: pause after installation; resume over SSH with clearme-continue");
    try option(out, color, "--allow-unverified", "Allow downloads without SHA-256 (rejected by default)");
    try option(out, color, "--verify-signatures=false", "Disable local GPG metadata signature verification (enabled by default)");
    try option(out, color, "--keyring PATH", "Local trusted GPG keyring");

    try section(out, color, "Defaults");
    try dimLine(out, color, "stable | ext4 | automatic UEFI/BIOS | Asia/Shanghai | automatic security updates | installer SSH | automatic swap on low RAM");

    try section(out, color, "Examples");
    try dimLine(out, color, "clearme --version 13 --china --hostname web01");
    try dimLine(out, color, "clearme --keep-data --dry-run");
    try dimLine(out, color, "clearme --filesystem btrfs --btrfs-compress zstd:3");
    if (color) {
        try out.print("\n\x1b[2mDocumentation: https://github.com/lovez-dev/clearme\x1b[0m\n", .{});
    } else {
        try out.print("\nDocumentation: https://github.com/lovez-dev/clearme\n", .{});
    }
}

fn section(out: *std.Io.Writer, color: bool, title: []const u8) !void {
    if (color) {
        try out.print("\n\x1b[1;36m{s}\x1b[0m\n", .{title});
    } else {
        try out.print("\n{s}\n", .{title});
    }
}

fn option(out: *std.Io.Writer, color: bool, flags: []const u8, desc: []const u8) !void {
    if (color) {
        try out.print("  \x1b[36m{s:<32}\x1b[0m {s}\n", .{ flags, desc });
    } else {
        try out.print("  {s:<32} {s}\n", .{ flags, desc });
    }
}

fn dimLine(out: *std.Io.Writer, color: bool, s: []const u8) !void {
    if (color) {
        try out.print("  \x1b[2m{s}\x1b[0m\n", .{s});
    } else {
        try out.print("  {s}\n", .{s});
    }
}

test "plain usage renders every section" {
    var buf: [8192]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try print(&fbs, false);
    const text = fbs.buffered();
    for (.{
        "Debian network reinstall tool",
        "clearme status",
        "--swap-size SIZE",
        "clearme --version 13 --china --hostname web01",
        "Documentation: https://github.com/lovez-dev/clearme",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, text, needle) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b[") == null);
}
