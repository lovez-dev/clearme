#!/bin/sh
# Block the installer, leaving SSH running until an authenticated user resumes.
set -eu
mkdir -p /run/clearme-control
chmod 1777 /run/clearme-control
cat > /usr/bin/clearme-continue <<'CONTINUE'
#!/bin/sh
touch /run/clearme-control/continue
CONTINUE
chmod 755 /usr/bin/clearme-continue
echo 'clearme: Installation is paused. Log in through SSH and run clearme-continue to resume.'
while [ ! -f /run/clearme-control/continue ]; do sleep 2; done
