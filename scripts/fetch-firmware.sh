#!/bin/sh
# Fetches the DiB0700 bridge firmware from linux-firmware into firmware/.
set -eu
cd "$(dirname "$0")/.."
mkdir -p firmware
f=firmware/dvb-usb-dib0700-1.20.fw
curl -fL -o "$f" \
  https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/dvb-usb-dib0700-1.20.fw
echo "415bd83150ebca3ed3ba8c1f74bf0b6a8a225c01  $f" | shasum -c -
