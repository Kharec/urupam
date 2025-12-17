#!/bin/bash
# simple helper to deploy urupam

# fail-fast
set -euo pipefail

# get root or get out
if [[ $(id -u) != 0 ]]; then
  echo "Please use sudo or run as root."
  exit 1
fi

# check carton
if ! command -v carton &>/dev/null; then
  echo "carton not found."
  exit 1
fi

# check redis
if ! ss -ltn | grep -q ":6379"; then
  echo "Redis isn't running, check README."
fi

# create urupam user
groupadd urupam
useradd -s /bin/bash -g urupam -d /opt/urupam urupam

# deploy code
cp -r bin lib cpan* /opt/urupam
chown -R urupam:urupam /opt/urupam

# install dependencies
su - urupam -c "cd /opt/urupam && carton install ."

# create systemd service
cat >>/etc/systemd/system/urupam.service <<EOF
[Unit]
Description=Urupam
After=network.target

[Service]
Type=simple
User=urupam
Group=urupam
WorkingDirectory=/opt/urupam
ExecStart=carton exec -- bin/urupam
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

# install documentation
mkdir -p /usr/share/doc/urupam
cp README.md LICENSE /usr/share/doc/urupam

# enable and start service
systemctl enable --now urupam

exit 0
