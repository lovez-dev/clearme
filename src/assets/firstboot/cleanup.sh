#!/bin/sh
set -u
mkdir -p /var/lib/clearme
LOG=/var/log/clearme-cleanup.log
exec >>"$LOG" 2>&1
export DEBIAN_FRONTEND=noninteractive
fail() {
    printf 'failed: cleanup (%s)\n' "$1" > /var/lib/clearme/cleanup-status
    systemctl disable clearme-cleanup.service 2>/dev/null || true
    exit "$1"
}
apt-get autoremove --purge -y || fail $?
apt-get clean || fail $?
printf 'complete\n' > /var/lib/clearme/cleanup-status
systemctl disable clearme-cleanup.service 2>/dev/null || true
rm -f /etc/systemd/system/clearme-cleanup.service /etc/systemd/system/multi-user.target.wants/clearme-cleanup.service
rm -rf /root/.clearme
systemctl daemon-reload 2>/dev/null || true
rm -f "$LOG"
