`payload/*.json` and `payload/*.cpio` are reference configurations and exact
archive outputs originally generated from the Go implementation at commit `24cd656`.
They cover EFI/root, BIOS/kept partitions with optional features, and minimal
configuration. Tests consume these files directly and do not require Go.
Archive paths and modes retain the historical outputs. Obsolete localized
comments have been removed and user-facing messages translated into English;
the archives were not regenerated from the Zig implementation.
Installer templates that intentionally gained hold controls, onlink routing and
failure preservation are allowed to differ from the historical Go fixtures.

`udeb.tar` is a Python tarfile PAX fixture containing an existing libc, sshd,
a symlink, a hardlink, a long path and an escaping path. It exercises archive
conversion without fetching or installing Debian packages.
