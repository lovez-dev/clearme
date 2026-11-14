const std = @import("std");
const builtin = @import("builtin");
const System = @import("system.zig").System;
const Options = @import("options.zig").Options;
const Transport = @import("transport.zig").Transport;
const mirror = @import("mirror.zig");
const release = @import("release.zig");
const detect = @import("detect.zig");
const netconf = @import("netconf.zig");
const keepdata = @import("keepdata.zig");
const payload = @import("payload.zig");
const grub = @import("grub.zig");
const guard = @import("guard.zig");

pub const App = struct {
    sys: *System,
    out: *std.Io.Writer,
    log_file: ?std.Io.File = null,
    log_offset: u64 = 0,

    fn message(self: *App, comptime fmt: []const u8, args: anytype) !void {
        const line = try std.fmt.allocPrint(self.sys.allocator, fmt ++ "\n", args);
        try self.out.writeAll(line);
        try self.out.flush();
        if (self.log_file) |file| {
            const stamp = try std.fmt.allocPrint(self.sys.allocator, "[{d}] {s}", .{ std.Io.Clock.real.now(self.sys.io).nanoseconds, line });
            try file.writePositionalAll(self.sys.io, stamp, self.log_offset);
            self.log_offset += stamp.len;
        }
    }

    pub fn status(self: *App) !void {
        try self.message("clearme {s}\n", .{@import("version.zig").version});
        var found = false;
        for ([_][]const u8{ "/boot/clearme/linux", "/boot/clearme/initrd.gz", "/boot/clearme/firmware.cpio.gz" }) |path| {
            const stat = std.Io.Dir.cwd().statFile(self.sys.io, path, .{}) catch continue;
            found = true;
            try self.message("  Installer file  {s} ({d} bytes)", .{ path, stat.size });
        }
        if (!found) try self.message("  Installer files  not prepared", .{});
        try self.message("  GRUB entry  {s}", .{if (grub.installed(self.sys)) "installed" else "not installed"});
        const next = grub.nextEntry(self.sys);
        try self.message("  Next boot  {s}", .{if (next.len > 0) next else "normal boot"});
        if (self.sys.pathExists("/etc/systemd/system/clearme-firstboot.service")) try self.message("  First boot service  installed", .{});
        const firstboot_state = self.sys.readOptional("/var/lib/clearme/firstboot-status");
        if (firstboot_state.len > 0) try self.message("  First boot result  {s}", .{std.mem.trim(u8, firstboot_state, " \t\r\n")});
        const cleanup_state = self.sys.readOptional("/var/lib/clearme/cleanup-status");
        if (cleanup_state.len > 0) try self.message("  Cleanup result  {s}", .{std.mem.trim(u8, cleanup_state, " \t\r\n")});
        for (log_paths) |path| if (self.sys.pathExists(path)) {
            try self.message("  Log  {s}", .{path});
        };
    }

    pub fn logs(self: *App, kind: []const u8) !void {
        const index: ?usize = if (kind.len == 0 or std.mem.eql(u8, kind, "clearme")) 0 else if (std.mem.eql(u8, kind, "firstboot")) 1 else if (std.mem.eql(u8, kind, "cleanup")) 2 else if (std.mem.eql(u8, kind, "all")) null else return self.sys.fail("Unknown log type: {s} (clearme/firstboot/cleanup/all)", .{kind});
        var printed = false;
        for (log_paths, 0..) |path, i| {
            if (index != null and index.? != i) continue;
            const data = tailFile(self.sys, path, 80, 512 << 10) catch |err| switch (err) {
                error.FileNotFound => continue,
                error.AccessDenied => {
                    try self.message("Cannot read {s} (root required)", .{path});
                    continue;
                },
                else => return err,
            };
            printed = true;
            try self.message("==> {s} <==", .{path});
            try self.out.writeAll(data);
            if (!std.mem.endsWith(u8, data, "\n")) try self.out.writeByte('\n');
        }
        if (!printed) try self.message("No clearme logs found (preparation writes /var/log/clearme.log)", .{});
    }

    pub fn reset(self: *App) !void {
        if (builtin.os.tag != .linux) return self.sys.fail("reset must run on the target Linux system", .{});
        try grub.reset(self.sys);
        try self.message("Reinstallation canceled; normal boot restored and /boot/clearme removed", .{});
    }

    pub fn execute(self: *App, o: Options) !void {
        if (o.dry_run) return self.dryRun(o);
        if (builtin.os.tag != .linux) return self.sys.fail("This platform supports only --dry-run; run clearme on the Debian system to reinstall", .{});
        try self.prepare(o);
    }

    fn transport(self: *App, o: Options) Transport {
        return .{ .sys = self.sys, .proxy = o.proxy, .allow_unverified = o.allow_unverified, .verify_signatures = o.verify_signatures, .keyring = o.keyring };
    }

    fn userMirror(self: *App, o: Options) !?mirror.Mirror {
        if (o.mirror.len == 0) return null;
        const uri = try std.Uri.parse(o.mirror);
        const start = (std.mem.indexOf(u8, o.mirror, "://") orelse return error.InvalidMirror) + 3;
        const end = std.mem.indexOfScalarPos(u8, o.mirror, start, '/') orelse o.mirror.len;
        return .{ .protocol = uri.scheme, .host = o.mirror[start..end], .directory = if (uri.path.isEmpty()) "/debian" else try uri.path.toRawMaybeAlloc(self.sys.allocator) };
    }

    fn candidates(self: *App, o: Options, suite_name: []const u8) ![]const mirror.Mirror {
        const a = self.sys.allocator;
        if (o.china) {
            const domestic = try self.transport(o).byLatency(&mirror.china_mirrors, suite_name);
            const defaults = mirror.candidates(null);
            return std.mem.concat(a, mirror.Mirror, &.{ domestic, &defaults });
        }
        return a.dupe(mirror.Mirror, &mirror.candidates(try self.userMirror(o)));
    }

    fn suite(self: *App, o: Options) !release.Info {
        if (!release.stableAlias(o.suite)) return release.resolve(o.suite);
        const a = self.sys.allocator;
        var failures: std.ArrayList(u8) = .empty;
        for (try self.candidates(o, "stable")) |m| {
            const text = self.transport(o).fetchRelease(try m.base(a), "stable") catch {
                const detail = self.sys.failure orelse "request failed";
                try failures.appendSlice(a, try std.fmt.allocPrint(a, "{s}: {s}\n", .{ try m.base(a), detail }));
                continue;
            };
            if (release.parseStable(text)) |info| return info;
            try failures.appendSlice(a, try std.fmt.allocPrint(a, "{s}: signed Release has no supported Debian codename/version\n", .{try m.base(a)}));
        }
        return self.sys.fail("Cannot resolve the current stable release. Mirror checks:\n{s}Specify --version to select a release directly.", .{failures.items});
    }

    fn previewMirror(self: *App, o: Options, suite_name: []const u8) !mirror.Mirror {
        if (o.china) {
            const list = try self.transport(o).byLatency(&mirror.china_mirrors, suite_name);
            if (list.len > 0) return list[0];
        } else if (try self.userMirror(o)) |m| return m;
        return .{ .host = "deb.debian.org" };
    }

    const Selection = struct { selected: mirror.Mirror, bases: []const []const u8 };
    fn selectMirror(self: *App, o: Options, info: release.Info, arch: []const u8) !Selection {
        const a = self.sys.allocator;
        if (info.daily) return .{ .selected = try self.previewMirror(o, info.suite), .bases = try a.dupe([]const u8, &.{try mirror.dailyNetbootDir(a, arch)}) };
        const cands = try self.candidates(o, info.suite);
        for (cands) |m| {
            const base = try m.netbootDir(a, info.suite, arch);
            if (!self.transport(o).ping(try std.fmt.allocPrint(a, "{s}/linux", .{base}))) continue;
            var bases: std.ArrayList([]const u8) = .empty;
            try bases.append(a, base);
            for (cands) |fallback| {
                const other = try fallback.netbootDir(a, info.suite, arch);
                if (!std.mem.eql(u8, other, base)) try bases.append(a, other);
            }
            return .{ .selected = m, .bases = try bases.toOwnedSlice(a) };
        }
        return self.sys.fail("No mirror provides the {s}/{s} installer", .{ info.suite, arch });
    }

    fn dryRun(self: *App, o: Options) !void {
        if (o.cidata.len > 0) _ = try @import("cloudinit.zig").load(self.sys, o.cidata);
        const info = self.suite(o) catch blk: {
            if (!release.stableAlias(o.suite)) return error.UnsupportedRelease;
            try self.message("Cannot resolve stable; using Debian 13 for preview", .{});
            break :blk try release.resolve("13");
        };
        const network = detect.network(self.sys, o, info.number) catch detect.Network{ .config = .{}, .options = .{} };
        const target = if (o.disk.len > 0) o.disk else detect.disk(self.sys, "") catch "/dev/sda (example)";
        var keep: std.ArrayList(u32) = .empty;
        if (o.keep_data) {
            if (o.keep_parts.len == 0) try keep.append(self.sys.allocator, 2);
            for (o.keep_parts) |part| {
                const num = keepdata.partNum(part);
                if (num > 0) try keep.append(self.sys.allocator, num);
            }
        }
        try self.message("clearme {s} | dry-run\nPreview only; no installer downloads or system changes.", .{@import("version.zig").version});
        try self.summary(o, info, detect.arch(self.sys) catch "amd64", target, network.config, try detect.hostname(self.sys, o.hostname), try self.previewMirror(o, info.suite), keep.items, o.password, false);
        if (o.keep_data) try self.message("Preserved partitions are examples; actual partitions and mount points are checked during preparation.", .{});
    }

    fn summary(self: *App, o: Options, info: release.Info, arch: []const u8, target: []const u8, n: netconf.Net, host: []const u8, m: mirror.Mirror, keep: []const u32, password: []const u8, random: bool) !void {
        const a = self.sys.allocator;
        try self.message("\n---- Debian {s} ({s}, {s}{s}) ----", .{ release.display(info.suite), info.suite, arch, if (o.firmware) ", firmware" else "" });
        try self.message("Auto updates  {s}\nProtection  {s}", .{ if (o.unattended) "unattended-upgrades (security updates)" else "off", if (o.fail2ban) "fail2ban" else "off" });
        try self.message("APT mirror  {s}\nSecurity mirror  {s}", .{ try m.base(a), (try release.securityRepo(a, m.protocol, m.host, m.directory, info.suite, info.daily)) orelse "none (daily build or sid)" });
        for (o.apt_repos) |repo| try self.message("Extra source  {s}", .{repo});
        try self.message("Time zone  {s} | NTP {s}\nInterface  {s}", .{ o.timezone, o.ntp, n.iface });
        if (n.has_v4) try self.message("IPv4      {s} {s}/{d} -> {s}", .{ if (n.static) "static" else "DHCP", n.ip, n.prefix, n.gateway }) else try self.message("IPv4      none", .{});
        if (n.v6.present()) try self.message("IPv6      {s} {s}/{d} -> {s}", .{ if (n.v6.static) "static" else if (n.v6.dhcpv6) "DHCPv6" else "SLAAC", n.v6.address, n.v6.prefix, n.v6.gateway }) else try self.message("IPv6      none", .{});
        const dns = try n.dns(a);
        try self.message("DNS       {s}", .{if (dns.len > 0) try std.mem.join(a, " ", dns) else if (n.present()) "provided by DHCP/RA" else "none"});
        if (o.proxy.len > 0) try self.message("Proxy      {s}", .{try redactProxy(a, o.proxy)});
        if (o.post_install.len > 0) try self.message("Post-install script {s}", .{o.post_install});
        for (keep) |num| try self.message("Preserve partition  {s} partition {d}", .{ target, num });
        try self.message("Target     {s} | {s} ({s}{s}{s})", .{ if (detect.useEFI(self.sys, o.boot_mode)) "UEFI" else "BIOS", target, o.filesystem, if (o.btrfs_compress.len > 0) ", compress=" else "", o.btrfs_compress });
        try self.message("Install parameters  kernel {s} ? ESP {d} MB ? system {s} ? hold {d}\nDownload checks  {s}", .{ try detect.kernelPackage(a, o, arch), o.esp_size, if (o.system_size.len > 0) o.system_size else "all available space", o.hold, if (o.allow_unverified) "unverified downloads allowed" else "SHA-256 required" });
        try self.message("GPG signatures  {s}", .{if (o.verify_signatures) "verify using local trusted keyrings" else "explicitly disabled"});
        if (o.bpo_kernel) try self.message("Kernel source  {s}", .{try release.backportsSuite(a, info)});
        if (o.cidata.len > 0) try self.message("cloud-init local NoCloud seed directory: {s}", .{o.cidata});
        try self.message("---- Login details ----\nHostname  {s}\nUser  {s}{s}", .{ host, o.user, if (o.authorized_keys_url.len > 0) " | public key authentication" else "" });
        const addresses = try @import("publicip.zig").loginAddresses(self.sys, n);
        if (addresses.v4.len > 0) try self.message("Login address  {s}:{d}", .{ addresses.v4, o.ssh_port });
        if (addresses.v6.len > 0) try self.message("Login address  [{s}]:{d}", .{ addresses.v6, o.ssh_port });
        // Credentials are displayed once, and are never copied into the log.
        try self.out.print("Password  {s}{s}\n--------------------------\n", .{ if (password.len > 0) password else "not specified (randomly generated during preparation)", if (random) " <- randomly generated; save it now" else "" });
        try self.out.flush();
    }

    fn prepare(self: *App, o: Options) !void {
        const sys = self.sys;
        const a = sys.allocator;
        if (o.firmware) try detect.checkFirmwareHost(sys);
        const warnings = try guard.check(sys, o.force);
        for (warnings) |warning| try self.message("Warning: {s}", .{warning});
        if (!sys.commandExists("curl")) return sys.fail("curl not found; install it with apt install curl", .{});
        if (o.installer_ssh and !sys.commandExists("dpkg-deb")) return sys.fail("dpkg-deb not found; installer SSH requires dpkg", .{});
        if (o.verify_signatures) {
            const signing = @import("signing.zig");
            try signing.check(sys, o.keyring);
            if (o.firmware and o.keyring.len == 0 and !sys.pathExists(signing.role_keyring))
                return sys.fail("Firmware signature verification requires debian-keyring (Debian CD role keys); install it or provide --keyring", .{});
        }
        const cloud_seed = if (o.cidata.len > 0) try @import("cloudinit.zig").load(sys, o.cidata) else @import("cloudinit.zig").Seed{};
        self.log_file = try std.Io.Dir.cwd().createFile(sys.io, o.log_file, .{ .truncate = false, .permissions = .fromMode(0o600) });
        defer {
            self.log_file.?.close(sys.io);
            self.log_file = null;
        }
        self.log_offset = (try self.log_file.?.stat(sys.io)).size;
        try self.message("Starting clearme {s}", .{@import("version.zig").version});
        const info = try self.suite(o);
        const arch = try detect.arch(sys);
        if (o.cloud_kernel and info.number == 11 and std.mem.eql(u8, arch, "arm64")) return sys.fail("Debian 11 arm64 has no standard cloud kernel package; select an available kernel with --kernel", .{});
        const password = if (o.password.len > 0) o.password else try @import("crypt.zig").randomPassword(sys.io, a, 16);
        const salt = @import("crypt.zig").randomSalt(sys.io);
        const hash = try @import("crypt.zig").sha512Crypt(a, password, &salt);
        const network = try detect.network(sys, o, info.number);
        const n = network.config;
        const target = try detect.disk(sys, o.disk);
        const efi = detect.useEFI(sys, o.boot_mode);
        if (o.system_size_mb > 0) {
            const raw = try sys.output(&.{ "lsblk", "-bdno", "SIZE", target });
            const bytes = try std.fmt.parseInt(u64, raw, 10);
            const required = (@as(u64, o.system_size_mb) + (if (efi) @as(u64, o.esp_size) else 1) + 4) * 1000000;
            if (bytes < required) return sys.fail("--system-size exceeds the target disk capacity after boot partition overhead", .{});
        }
        const kernel = try detect.kernelPackage(a, o, arch);
        const backports = if (o.bpo_kernel) release.backportsSuite(a, info) catch return sys.fail("This release has no supported backports repository", .{}) else "";
        var label = try detect.diskLabel(sys, target);
        if (efi and !std.mem.eql(u8, label, "gpt")) {
            if (o.keep_data) return sys.fail("UEFI --keep-data requires a GPT partition table", .{});
            label = "gpt";
        }
        const disk_id = try detect.diskID(sys, target);
        const part_uuid = detect.partUUID(sys, target);
        if (disk_id.len == 0 and part_uuid.len == 0) try self.message("Warning: cannot read disk identifiers; installer will fall back to device name {s}", .{target});
        var keep: std.ArrayList(u32) = .empty;
        var fstab: std.ArrayList(payload.FstabEntry) = .empty;
        if (o.keep_data) {
            const parts = try keepdata.analyze(sys, target, detect.rootDevice(sys), o.keep_parts);
            var data_index: usize = 0;
            for (parts) |part| {
                if (std.mem.eql(u8, label, "msdos") and part.num > 4) return sys.fail("Cannot preserve logical partition {s} on an msdos disk", .{part.path});
                try keep.append(a, part.num);
                var mount: []const u8 = "not mounted";
                if (keepdata.isMountable(part.fs_type)) {
                    if (part.part_uuid.len == 0) return sys.fail("Partition {s} has no PARTUUID", .{part.path});
                    mount = try keepdata.mountPointFor(a, data_index);
                    data_index += 1;
                    try fstab.append(a, .{ .PartUUID = part.part_uuid, .MountPoint = mount, .FSType = part.fs_type, .Pass = keepdata.fstabPass(part.fs_type) });
                }
                try self.message("Preserve {s} ({s}, {s}) -> {s}", .{ part.path, part.fs_type, part.size, mount });
                if (part.mountpoint.len > 0) try self.message("Warning: {s} is mounted at {s}; unmount it before reinstallation", .{ part.path, part.mountpoint });
            }
            try self.message("Warning: --keep-data installs into the largest free region; other unpreserved partitions will be deleted.", .{});
            const all_disks = try detect.rootDisks(a, sys.optional(&.{ "lsblk", "-p", "-dn", "-o", "NAME,TYPE" }));
            for (all_disks) |other| if (!std.mem.eql(u8, target, other)) {
                try self.message("Warning: additional disk {s} detected; the installer may select its free space.", .{other});
            };
        }
        const selection = try self.selectMirror(o, info, arch);
        const m = selection.selected;
        const t = self.transport(o);
        if (o.bpo_kernel) {
            const metadata = t.fetchRelease(try m.base(a), backports) catch return sys.fail("Cannot verify or read repository {s}; check release, mirror and keyring", .{backports});
            if (!std.mem.eql(u8, @import("signing.zig").codename(metadata) orelse "", backports)) return sys.fail("Backports repository codename mismatch", .{});
        }
        const keys = if (o.authorized_keys_url.len > 0) try t.fetchText(o.authorized_keys_url, 1 << 20) else "";
        const post = if (o.post_install.len == 0) "" else if (isHTTP(o.post_install)) try t.fetchText(o.post_install, 1 << 20) else try localScript(sys, o.post_install);
        try self.checkBootSpace();
        try sys.mkdir("/boot/clearme");
        try std.Io.Dir.cwd().setFilePermissions(sys.io, "/boot/clearme", .fromMode(0o700), .{});
        var downloader: Downloader = .{ .app = self, .transport = t, .allow_unverified = o.allow_unverified, .cache = std.StringHashMap(?mirror.Checksums).init(a) };
        try self.message("Downloading and verifying installer kernel and initrd ...", .{});
        try downloader.file(selection.bases, "linux", "/boot/clearme/linux");
        try downloader.file(selection.bases, "initrd.gz", "/boot/clearme/initrd.gz");
        if (o.firmware) {
            const firmware_base = try std.fmt.allocPrint(a, "https://cdimage.debian.org/cdimage/unofficial/non-free/firmware/{s}/current", .{info.suite});
            try downloader.file(&.{firmware_base}, "firmware.cpio.gz", "/boot/clearme/firmware.cpio.gz");
        }
        const host = try detect.hostname(sys, o.hostname);
        const security = (try release.securityRepo(a, m.protocol, m.host, m.directory, info.suite, info.daily)) orelse "";
        const mb = guard.memoryMB(sys);
        const cfg: payload.Config = .{
            .Interface = n.iface,
            .Static = n.static,
            .IP = n.ip,
            .Netmask = n.netmask,
            .Gateway = n.gateway,
            .DNS = try std.mem.join(a, " ", try n.dns(a)),
            .Hostname = host,
            .Interfaces = if (n.present()) try netconf.renderInterfaces(a, n, network.options) else "",
            .ResolvConf = if ((try n.dns(a)).len > 0) try netconf.renderResolvConf(a, try n.dns(a), n.resolv_other) else "",
            .MirrorProtocol = m.protocol,
            .MirrorHost = m.host,
            .MirrorDir = m.directory,
            .Suite = info.suite,
            .SecurityRepo = security,
            .SecuritySuite = try release.securitySuite(a, info.suite),
            .Timezone = o.timezone,
            .NTP = o.ntp,
            .Disk = target,
            .DiskLabel = label,
            .EFI = efi,
            .ESPSize = o.esp_size,
            .SystemSize = o.system_size,
            .SystemSizeMB = o.system_size_mb,
            .Kernel = kernel,
            .BackportsSuite = backports,
            .CloudInit = o.cidata.len > 0,
            .CloudNetwork = cloud_seed.has_network,
            .CloudSeed = cloud_seed,
            .HoldBefore = o.hold == 1,
            .HoldAfter = o.hold == 2,
            .InstallerOnlink = (n.static and netconf.v4GatewayOffSubnet(n.gateway, n.ip, n.prefix)) or (!n.has_v4 and n.v6.static),
            .IPPrefix = n.prefix,
            .InstallerV6Address = if (n.v6.static) n.v6.address else "",
            .InstallerV6Interface = if (n.v6.present()) n.v6.iface else "",
            .InstallerV6Prefix = n.v6.prefix,
            .InstallerV6Gateway = n.v6.gateway,
            .Filesystem = o.filesystem,
            .BtrfsCompress = o.btrfs_compress,
            .KeepParts = keep.items,
            .Arch = arch,
            .Username = o.user,
            .PasswordHash = hash,
            .Install = if (o.bpo_kernel) try std.fmt.allocPrint(a, "{s}/{s} {s}", .{ kernel, backports, try detect.installList(a, o) }) else try detect.installList(a, o),
            .Upgrade = o.upgrade,
            .SSHPort = o.ssh_port,
            .AuthorizedKeys = keys,
            .KeepFstab = fstab.items,
            .Optimize = o.optimize,
            .Swap = o.swap or (mb > 0 and mb < 1024),
            .SwapSize = if (o.swap_size.len > 0) o.swap_size else "1G",
            .SwapMB = if (o.swap_size.len > 0) o.swap_mb else 1024,
            .Packages = if (o.install.len > 0) o.install else "ca-certificates",
            .PostInstall = post,
            .ExtraRepos = o.apt_repos,
            .Unattended = o.unattended,
            .Fail2ban = o.fail2ban,
            .Proxy = o.proxy,
            .InstallerSSH = o.installer_ssh,
        };
        var entries: std.ArrayList(@import("cpio.zig").Entry) = .empty;
        if (o.installer_ssh) {
            try self.message("Preparing installer SSH ...", .{});
            try entries.appendSlice(a, try @import("diudeb.zig").inject(sys, t, m, info.suite, arch, "/boot/clearme/initrd.gz"));
        }
        try entries.appendSlice(a, try payload.build(a, cfg));
        try self.message("Writing preseed and helper scripts ...", .{});
        try @import("initrd.zig").appendCpio(sys.io, a, "/boot/clearme/initrd.gz", "/boot/clearme/initrd.gz", entries.items);
        try std.Io.Dir.cwd().setFilePermissions(sys.io, "/boot/clearme/initrd.gz", .fromMode(0o600), .{});
        const entry: grub.Entry = .{
            .kernel_path = try grub.relPath(sys, "/boot/clearme/linux"),
            .initrd_path = try grub.relPath(sys, "/boot/clearme/initrd.gz"),
            .firmware = if (o.firmware) try grub.relPath(sys, "/boot/clearme/firmware.cpio.gz") else "",
            .kernel_args = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ try detect.kernelArgs(a, target, keep.items, disk_id, part_uuid), if (o.force_lowmem.len > 0) " lowmem=+" else "", o.force_lowmem }),
        };
        try self.summary(o, info, arch, target, n, host, m, keep.items, password, o.password.len == 0);
        if (!o.yes and !try self.confirm()) {
            try self.message("Canceled: boot entry not written; downloads retained in /boot/clearme", .{});
            return;
        }
        try grub.install(sys, entry);
        grub.setOneTimeBoot(sys) catch {
            try self.message("Warning: {s}", .{sys.failure orelse "Cannot set one-time boot; select Debian Installer (clearme) manually"});
        };
        if (o.installer_ssh) try self.message("Installer SSH: user {s}, port {d}; progress: tail -fn+1 /var/log/syslog", .{ o.user, o.ssh_port });
        if (o.reboot) {
            try self.message("Preparation complete; rebooting into the Debian installer.", .{});
            _ = try sys.run(&.{"sync"});
            try sys.inherit(&.{"reboot"});
        } else try self.message("Reboot to start installation. Run clearme reset before rebooting to cancel.", .{});
    }

    fn checkBootSpace(self: *App) !void {
        var lines = std.mem.splitScalar(u8, self.sys.optional(&.{ "df", "-Pk", "/boot" }), '\n');
        _ = lines.next();
        var words = std.mem.tokenizeAny(u8, lines.next() orelse return, " \t");
        for (0..3) |_| _ = words.next();
        const available = std.fmt.parseInt(u64, words.next() orelse return, 10) catch return;
        if (available < 300 * 1024) try self.message("Warning: only {d} MB free in /boot; at least 300 MB recommended", .{available / 1024});
    }

    fn confirm(self: *App) !bool {
        try self.message("\nThe installer boot entry will be written. The next boot will repartition the disk and erase the current system.\nContinue? [y/N]:", .{});
        const tty = std.Io.Dir.cwd().openFile(self.sys.io, "/dev/tty", .{}) catch null;
        defer if (tty) |file| file.close(self.sys.io);
        const file = tty orelse std.Io.File.stdin();
        var buffer: [256]u8 = undefined;
        var reader = file.reader(self.sys.io, &buffer);
        const answer = reader.interface.takeDelimiterExclusive('\n') catch return false;
        const value = std.mem.trim(u8, answer, " \t\r\n");
        return std.ascii.eqlIgnoreCase(value, "y") or std.ascii.eqlIgnoreCase(value, "yes");
    }
};

const log_paths = [_][]const u8{ "/var/log/clearme.log", "/var/log/clearme-firstboot.log", "/var/log/clearme-cleanup.log" };

pub fn tailFile(sys: *System, path: []const u8, count: usize, limit: usize) ![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(sys.io, path, .{});
    defer file.close(sys.io);
    const stat = try file.stat(sys.io);
    const length: usize = @intCast(@min(stat.size, limit));
    const buffer = try sys.allocator.alloc(u8, length);
    const used = try file.readPositionalAll(sys.io, buffer, stat.size - length);
    const bytes = buffer[0..used];
    var pos = bytes.len;
    if (pos > 0 and bytes[pos - 1] == '\n') pos -= 1;
    var lines: usize = 0;
    while (pos > 0) {
        pos -= 1;
        if (bytes[pos] == '\n') {
            lines += 1;
            if (lines == count) return bytes[pos + 1 ..];
        }
    }
    return bytes;
}

pub fn redactProxy(a: std.mem.Allocator, value: []const u8) ![]const u8 {
    const scheme = std.mem.indexOf(u8, value, "://") orelse return value;
    const end = std.mem.indexOfScalarPos(u8, value, scheme + 3, '/') orelse value.len;
    const at = std.mem.lastIndexOfScalar(u8, value[scheme + 3 .. end], '@') orelse return value;
    return std.mem.concat(a, u8, &.{ value[0 .. scheme + 3], "redacted@", value[scheme + 4 + at ..] });
}

fn isHTTP(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "http://") or std.mem.startsWith(u8, value, "https://");
}

pub fn localScript(sys: *System, path: []const u8) ![]const u8 {
    const stat = try std.Io.Dir.cwd().statFile(sys.io, path, .{});
    if (stat.kind != .file or stat.size > 1 << 20) return sys.fail("Post-install script must be a regular file no larger than 1 MiB: {s}", .{path});
    return sys.read(path, 1 << 20);
}

pub const Downloader = struct {
    app: *App,
    transport: Transport,
    cache: std.StringHashMap(?mirror.Checksums),
    allow_unverified: bool = false,

    pub fn file(self: *Downloader, bases: []const []const u8, name: []const u8, destination: []const u8) !void {
        const sys = self.app.sys;
        for (bases) |base| {
            const cached = try self.cache.getOrPut(base);
            if (!cached.found_existing) cached.value_ptr.* = self.transport.fetchChecksums(base) catch |err| blk: {
                try self.app.message("Mirror metadata verification failed: {s}", .{sys.failure orelse @errorName(err)});
                break :blk null;
            };
            const sums = cached.value_ptr.*;
            const sum = if (sums) |map| map.get(name) else null;
            if (sum) |digest| {
                if (mirror.verifyFile(sys.io, destination, &digest)) |_| {
                    try self.app.message("{s} already exists and passes SHA-256 verification", .{name});
                    return;
                } else |_| {}
            } else {
                try self.app.message("{s}: mirror {s} does not provide SHA-256 for {s}", .{ if (self.allow_unverified) "Warning, unverified downloads explicitly allowed" else "Download refused", base, name });
                if (self.transport.verify_signatures or !self.allow_unverified) continue;
            }
            const url = try std.fmt.allocPrint(sys.allocator, "{s}/{s}", .{ base, name });
            self.transport.download(url, destination) catch {
                try self.app.message("Mirror download failed; trying the next mirror: {s}", .{base});
                continue;
            };
            if (sum) |digest| mirror.verifyFile(sys.io, destination, &digest) catch {
                sys.remove(destination);
                sys.remove(try std.fmt.allocPrint(sys.allocator, "{s}.part", .{destination}));
                try self.app.message("Mirror file verification failed; trying the next mirror: {s}", .{base});
                continue;
            };
            return;
        }
        return sys.fail("All mirrors failed to download {s}", .{name});
    }
};

test "proxy credentials are redacted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("socks5://redacted@host:1080", try redactProxy(arena.allocator(), "socks5://user:secret@host:1080"));
}

const cli = @import("cli.zig");
const usage = @import("usage.zig");

pub const version = @import("version.zig").version;

/// Run the CLI and return its process exit code.
pub fn run(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var err_buf: [4096]u8 = undefined;
    var err_fw = std.Io.File.stderr().writer(init.io, &err_buf);
    const err_out = &err_fw.interface;

    var out_buf: [512]u8 = undefined;
    var out_fw = std.Io.File.stdout().writer(init.io, &out_buf);
    const out = &out_fw.interface;

    // Color follows fatih/color semantics: TTY + NO_COLOR/CLICOLOR_FORCE.
    const color = blk: {
        if (init.environ_map.get("NO_COLOR")) |v| if (v.len > 0) break :blk false;
        if (init.environ_map.get("CLICOLOR_FORCE")) |v| if (v.len > 0) break :blk true;
        break :blk std.Io.File.stderr().isTty(init.io) catch false;
    };
    // Subcommands bypass flag parsing, exactly like Go cli.Main.
    const sub = if (args.len > 1) args[1] else "";
    var sys: @import("system.zig").System = .{ .io = init.io, .allocator = init.arena.allocator() };
    var app: App = .{ .sys = &sys, .out = out };
    if (std.mem.eql(u8, sub, "help")) {
        try usage.print(err_out, color);
        try err_fw.flush();
        return 0;
    }
    if (std.mem.eql(u8, sub, "reset") or
        std.mem.eql(u8, sub, "status") or
        std.mem.eql(u8, sub, "logs"))
    {
        const result = if (std.mem.eql(u8, sub, "reset")) app.reset() else if (std.mem.eql(u8, sub, "status")) app.status() else app.logs(if (args.len > 2) args[2] else "");
        result catch |err| {
            try err_out.print("clearme: {s}\n", .{if (err == error.Failed) sys.failure orelse @errorName(err) else @errorName(err)});
            try err_fw.flush();
            try out_fw.flush();
            return 1;
        };
        try out_fw.flush();
        return 0;
    }

    const outcome = cli.parse(init.arena.allocator(), args) catch {
        try err_out.print("clearme: out of memory\n", .{});
        try err_fw.flush();
        return 1;
    };
    switch (outcome) {
        .help => {
            try usage.print(err_out, color);
            try err_fw.flush();
            return 0;
        },
        .fail => |msg| {
            try err_out.print("Error: {s}\n", .{msg});
            try usage.print(err_out, color);
            try err_fw.flush();
            return 2;
        },
        .ok => |opts| {
            if (opts.program_version) {
                try out.print("clearme {s}\n", .{version});
                try out_fw.flush();
                return 0;
            }
            app.execute(opts) catch |err| {
                try err_out.print("clearme: {s}\n", .{if (err == error.Failed) sys.failure orelse @errorName(err) else @errorName(err)});
                try err_fw.flush();
                try out_fw.flush();
                return 1;
            };
        },
    }

    try out_fw.flush();
    return 0;
}

test "version parses" {
    _ = try std.SemanticVersion.parse(version);
}

test {
    _ = cli;
    _ = @import("detect.zig");
    _ = @import("publicip.zig");
    _ = @import("crypt.zig");
    _ = @import("cpio.zig");
    _ = @import("initrd.zig");
    _ = @import("system.zig");
    _ = @import("keepdata.zig");
    _ = @import("guard.zig");
    _ = @import("grub.zig");
    _ = @import("template.zig");
    _ = @import("payload.zig");
    _ = @import("transport.zig");
    _ = @import("diudeb.zig");
    _ = @import("netconf.zig");
    _ = @import("mirror.zig");
    _ = @import("release.zig");
}

pub fn main(init: std.process.Init) !void {
    const code = try run(init);
    if (code != 0) std.process.exit(code);
}
