#!/bin/sh
set -eu

# 适用于带 Docker 的 OpenWrt (x86_64 / arm64) 24小时不关机路由器
DATA_DIR="${1:-/mnt/data/atvloadly}"

opkg update
opkg install avahi-dbus-daemon dbus

/etc/init.d/dbus enable
/etc/init.d/dbus start
/etc/init.d/avahi-daemon enable
/etc/init.d/avahi-daemon start

mkdir -p "$DATA_DIR"

docker rm -f atvloadly 2>/dev/null || true
docker run -d \
  --name atvloadly \
  --restart always \
  --security-opt seccomp:unconfined \
  -p 5533:80 \
  -v "$DATA_DIR:/data" \
  -v /var/run/dbus:/var/run/dbus \
  -v /var/run/avahi-daemon:/var/run/avahi-daemon \
  bitxeno/atvloadly:latest

echo "atvloadly deployed! Open http://<OpenWrt-LAN-IP>:5533 to pair Apple TV (tvOS 27)."
