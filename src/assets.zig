pub const preseed = @embedFile("assets/preseed.tmpl");
pub const firstboot = @embedFile("assets/firstboot/firstboot.sh.tmpl");
pub const cleanup = @embedFile("assets/firstboot/cleanup.sh");
pub const fix_eth_name = @embedFile("assets/firstboot/fix-eth-name.sh");
pub const fix_eth_name_service = @embedFile("assets/firstboot/fix-eth-name.service");
pub const partman_early = @embedFile("assets/partman/partman-early.sh");
pub const installer_ssh = @embedFile("assets/installer-ssh/installer-ssh.sh.tmpl");
pub const early = @embedFile("assets/installer/early.sh");
pub const netcfg_onlink = @embedFile("assets/installer/netcfg-onlink.sh.tmpl");
pub const wait = @embedFile("assets/installer/wait.sh");
pub const post_base_installer = @embedFile("assets/installer/post-base-installer.sh.tmpl");
pub const late = @embedFile("assets/late.sh.tmpl");
pub const optimize = .{
    .{ "10-sysctl.sh", @embedFile("assets/optimize/10-sysctl.sh") },
    .{ "20-limits.sh", @embedFile("assets/optimize/20-limits.sh") },
    .{ "30-journald.sh", @embedFile("assets/optimize/30-journald.sh") },
    .{ "40-logrotate.sh", @embedFile("assets/optimize/40-logrotate.sh") },
};
