# clearme

Reinstall Debian over the network. clearme prepares the Debian installer and adds a one-time GRUB boot entry. On the next reboot, the installer repartitions the target disk and installs a fresh system.

## Requirements

- An existing Debian Linux system with root access and GRUB2.
- `curl`, `iproute2`, `util-linux`, and `gpgv` with an up-to-date `debian-archive-keyring`.
- `dpkg-deb` for installer SSH, which is enabled by default.
- Secure Boot disabled. Keep backups and access to a provider recovery system or console before reinstalling.

Release binaries are provided for Linux amd64 and arm64. Native Windows builds support configuration previews and inspection commands; actual reinstallation requires Linux. Supported target release names include Debian 11, 12, 13, 14 and sid, or their codenames. Availability depends on Debian's installer and package repositories.

## Install

Run as root:

```sh
curl -fsSL https://raw.githubusercontent.com/lovez-dev/clearme/main/install.sh | sh
```

The script downloads the latest release, checks its SHA-256 against the release checksum file, and installs `/usr/local/bin/clearme`. To install and immediately pass arguments to clearme:

```sh
curl -fsSL https://raw.githubusercontent.com/lovez-dev/clearme/main/install.sh | sh -s -- --dry-run --version 13
```

## Quick start

Install clearme, prepare reinstallation, and reboot automatically:

```sh
curl -fsSL https://raw.githubusercontent.com/lovez-dev/clearme/main/install.sh \
  | sudo bash -s -- \
    --yes \
    --reboot-now \
    --user admin \
    --password 'YOUR_STRONG_PASSWORD'
```

Replace `admin` and `YOUR_STRONG_PASSWORD` with your login credentials. This command skips confirmation and immediately reboots after preparation; installation erases the current system.

For an existing clearme installation:

```sh
# Preview without downloading installer files or changing the system.
clearme --dry-run --version 13

# Prepare the installer, review the confirmation, then reboot manually.
clearme --version 13 --hostname web01
reboot

# Set an explicit disk, account and SSH port.
clearme --version 13 --disk /dev/vda --user admin --ssh-port 2222

# Use Btrfs with compression.
clearme --filesystem btrfs --btrfs-compress zstd:3

# Limit the root partition to 10 GiB; leave other available space unallocated.
clearme --system-size 10G

# Prepare and reboot without an interactive confirmation.
clearme --version 13 --yes --reboot-now
```

`--version` selects the **Debian release**. Use `-V` or `--program-version` for the clearme version. The default target follows Debian stable. Default settings include ext4, automatic BIOS/UEFI detection, the `Asia/Shanghai` time zone, automatic security updates, system tuning, and installer SSH. Swap is created automatically on systems with less than 1 GiB RAM unless configured explicitly.

The password is generated if omitted and displayed once in the login summary. Save it before rebooting.

## Monitor, pause or cancel

Installer SSH uses the configured account and port:

```sh
ssh -p 22 root@SERVER_IP
tail -fn+1 /var/log/syslog
dmesg -w
```

The login banner lists useful commands. When the installer runs in a screen session, it also shows the command to attach to the installer interface.

Use `--hold 1` to pause before partitioning or `--hold 2` to pause after the target system is installed under `/target`. Both require installer SSH. Resume with `clearme-continue`; mode 2 then finishes installation and reboots. A pause does not provide rollback after disk writes.

```sh
clearme status          # Installer files, GRUB entry and lifecycle results.
clearme logs            # Preparation log.
clearme logs firstboot  # First boot log, retained on failure.
clearme logs cleanup    # Cleanup log, retained on failure.
clearme logs all
clearme reset           # Cancel before reboot; remove the installer entry and files.
```

## Options

Boolean options accept `=false`. Run `clearme help` for the command-line reference.

| Option | Behavior |
| --- | --- |
| `--version VERSION` | Target release number or codename; defaults to stable. |
| `--mirror URL` | Debian mirror; defaults to `https://deb.debian.org/debian`. |
| `--china` | Select a Chinese mirror using speed tests. |
| `--proxy URL` | Proxy for downloads and target APT; accepts HTTP, HTTPS, SOCKS5 and SOCKS5h. |
| `--ip ADDR`, `--netmask MASK`, `--gateway ADDR` | Static IPv4 configuration; otherwise preserve the detected network mode. |
| `--ipv6 ADDR[/PREFIX]` | Static IPv6 address; retains the detected gateway unless overridden. |
| `--ipv6-gateway ADDR` | Explicit IPv6 gateway; requires `--ipv6`. |
| `--dns "ADDR ..."`, `--ipv6-dns "ADDR ..."` | DNS server overrides. |
| `--hostname NAME` | Hostname; defaults to the current hostname. |
| `--interface NAME` | Network interface; defaults to automatic selection from the default route. |
| `--user NAME` | Login account; defaults to `root`. |
| `--password PASS` | Login password; randomly generated if omitted. |
| `--ssh-port N` | SSH port for the installer and target system; defaults to 22. |
| `--authorized-keys-url URL` | Install SSH public keys and disable password authentication. |
| `--disk /dev/vda` | Target disk; defaults to the disk containing the current root filesystem. |
| `--filesystem ext4\|xfs\|btrfs` | Root filesystem; defaults to ext4. |
| `--btrfs-compress ALGO` | `zstd[:1-15]`, `zlib[:1-9]` or `lzo`; requires Btrfs. |
| `--boot-mode auto\|bios\|efi` | Target boot mode; does not change machine firmware settings. |
| `--esp MB` | EFI system partition size; minimum and default are 106 MB. |
| `--system-size SIZE` | Cap the root partition, e.g. `10G`; minimum 2G. Other available space remains unallocated. Boot partitions are additional. |
| `--keep-data` | Automatically identify and preserve one data partition. |
| `--keep-part /dev/vda3` | Preserve a specific partition; repeatable. Cannot combine with `--keep-data`. |
| `--install "PKG ..."` | Packages to install in addition to the base system. |
| `--upgrade none\|safe\|full` | Installation-stage APT upgrade; defaults to full. |
| `--post-install PATH\|URL` | Script to run on first boot; local regular file or HTTP(S) URL, up to 1 MiB. |
| `--apt-repo 'deb ...'` | Additional APT source; repeatable. |
| `--fail2ban` | Install fail2ban and enable SSH protection. |
| `--firmware` | Include Debian non-free firmware; physical machines only. Requires `systemd-detect-virt` and, with default signature verification, `debian-keyring` or a suitable `--keyring`. |
| `--swap-size SIZE` | Explicit swapfile size, e.g. `512M`, `2G` or `2048MB`; accepted range 64M to 1T. |
| `--timezone ZONE` | Time zone; defaults to `Asia/Shanghai`. |
| `--ntp HOST` | NTP server; an explicit value overrides the `--china` preset. |
| `--kernel PACKAGE` | Explicit kernel package; otherwise use `linux-image-ARCH`. |
| `--cloud-kernel` | Use `linux-image-cloud-ARCH`; mutually exclusive with `--kernel`. |
| `--bpo-kernel` | Use a backports kernel and configure the corresponding repository; Debian 12/13. |
| `--cidata DIR` | Local cloud-init NoCloud seed directory. |
| `--force-lowmem 0\|1\|2` | Debian installer low memory mode; does not increase available RAM. |
| `--optimize=false` | Disable first boot system tuning. |
| `--unattended=false` | Disable automatic security updates. |
| `--installer-ssh=false` | Disable installer SSH; incompatible with hold modes. |
| `--hold 0\|1\|2` | No pause, pause before partitioning, or pause after installation. |
| `--allow-unverified` | Allow missing SHA-256 metadata; checksum mismatches still fail. |
| `--verify-signatures=false` | Disable metadata signature verification; checksums remain enabled. |
| `--keyring PATH` | Local trusted GPG keyring override. |
| `--dry-run` | Print a configuration preview without preparing an installation. |
| `--yes` | Skip confirmation. |
| `--reboot-now` | Reboot immediately after preparation. |
| `--force` | Override selected environment checks; cannot bypass the firmware virtualization restriction. |
| `-V`, `--program-version` | Display the clearme version. |

## Storage and network behavior

Reinstallation deletes the current system. With preservation enabled, only the selected data partitions are retained; other partitions can be deleted. A root partition size cap does not preserve an existing partition by itself. UEFI preservation requires GPT. Prefer a data partition near the end of the disk and disconnect unrelated disks before using automatic partition placement on machines with multiple disks.

Static IPv4 `/32` addresses and gateways outside the address subnet use explicit gateway host routes and an `onlink` default route. Installer and target configurations retain the original address prefix. This is not verification of every provider's network environment.

`--firmware` rejects detected virtual machines and containers before downloading files or modifying boot configuration. Missing or inconclusive virtualization detection also causes an error. It is not a workaround for missing virtual network or storage drivers. Physical hardware firmware installation still needs separate validation.

## Download verification

Kernel, initrd, optional firmware and injected installer packages require SHA-256 metadata by default. Mirrors without usable metadata are skipped; a checksum mismatch always fails. Signature verification authenticates repository metadata using local Debian keyrings, then verifies downloaded files against its checksums.

Debian repositories use `InRelease` or `Release` plus `Release.gpg`. Firmware and daily build checksum directories use detached signatures. Keys come only from local keyrings, never from the download mirror. Firmware signatures need Debian CD role keys, normally supplied by `debian-keyring`.

`--verify-signatures=false` removes metadata authentication but retains checksum checks. `--allow-unverified` permits missing checksums only when signature requirements also allow the download. Neither option repairs corrupted files.

## First boot and cloud-init

First boot installs configured packages, applies optional tuning, creates swap, and runs the post-install script. A failure retains scripts and logs and disables automatic retries to avoid repeating a script with side effects. Inspect `clearme status`, `clearme logs firstboot`, or `clearme logs cleanup`. After fixing the problem and checking that rerunning is safe:

```sh
systemctl start clearme-firstboot.service
# For a failure in the separate cleanup service:
systemctl start clearme-cleanup.service
```

Successful completion removes temporary scripts and logs while retaining result status files under `/var/lib/clearme`.

`--cidata DIR` requires `meta-data` and `user-data`, copies the local NoCloud seed to `/var/lib/cloud/seed/nocloud`, and installs cloud-init. If `network-config` is present, cloud-init manages networking; otherwise clearme's ifupdown configuration remains in use. Only the four supported seed files are read, each limited to 1 MiB, without following symbolic links.

## Build and verify

Use **Zig 0.17.1**.

```sh
zig build
zig build run -- --dry-run --version 13
zig build test
zig build fmt
make checksums
```

Native binaries are written to `zig-out/bin`. `make checksums` produces static Linux amd64/arm64 release binaries and `dist/sha256sums.txt`. To cross-compile directly:

```sh
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe --prefix dist/amd64
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe --prefix dist/arm64
```

Unit tests include historical Go fixtures that retain archive structure and unchanged asset checks, with localized messages normalized to English. Unit tests do not replace real reboot and installation testing.

Before publishing a release, update both `src/version.zig` and `build.zig.zon`, then create the corresponding `v*` tag. Release artifact names must remain compatible with `install.sh`.

## License

See [LICENSE](LICENSE).
