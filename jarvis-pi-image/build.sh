#!/bin/bash
# Builds jarvis-pi.img.xz: Raspberry Pi OS Lite (32-bit, Bookworm, works on every Pi including the Pi 1 B+)
# with the Jarvis voice speaker built in. Needs root, losetup and qemu-user-static (GitHub's Ubuntu runners have them).
set -euo pipefail
cd "$(dirname "$0")"
HERE=$PWD
WORK=${WORK:-$HERE/work}
mkdir -p "$WORK" && cd "$WORK"

echo "== Downloading Raspberry Pi OS Lite (32-bit)"
for channel in raspios_oldstable_lite_armhf raspios_lite_armhf; do
  BASE="https://downloads.raspberrypi.com/$channel/images/"
  LATEST=$(curl -fsSL "$BASE" | grep -oE "$channel-[0-9-]+/" | sort -u | tail -n 1) || true
  [ -n "$LATEST" ] || continue
  IMG=$(curl -fsSL "$BASE$LATEST" | grep -oE '[A-Za-z0-9_.-]+\.img\.xz' | sort -u | head -n 1) || true
  [ -n "$IMG" ] || continue
  # Bookworm (the Pi 1 is fully supported there); the oldstable channel holds it once a newer release is out.
  if [ "$channel" = raspios_lite_armhf ] && ! echo "$IMG" | grep -q bookworm; then
    echo "   (current release isn't Bookworm: $IMG; using it anyway)"
  fi
  break
done
[ -n "${IMG:-}" ] || { echo "Couldn't find a Raspberry Pi OS image"; exit 1; }
echo "   $BASE$LATEST$IMG"
[ -f "$IMG" ] || curl -fL --retry 3 -o "$IMG" "$BASE$LATEST$IMG"
EXPECTED=$(curl -fsSL "$BASE$LATEST$IMG.sha256" | awk '{print $1}')
echo "$EXPECTED  $IMG" | sha256sum -c -
echo "$IMG" > base-image.txt

echo "== Unpacking and making room"
rm -f jarvis-pi.img
xz -dc -T0 "$IMG" > jarvis-pi.img
truncate -s +512M jarvis-pi.img
parted -s jarvis-pi.img resizepart 2 100%
LOOP=$(losetup -fP --show jarvis-pi.img)
ROOT=$WORK/root
cleanup() {
  set +e
  for m in dev/pts dev proc sys boot/firmware ""; do mountpoint -q "$ROOT/$m" && umount -l "$ROOT/$m"; done
  losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT
sleep 1
e2fsck -fy "${LOOP}p2" >/dev/null || true
resize2fs "${LOOP}p2" >/dev/null
mkdir -p "$ROOT"
mount "${LOOP}p2" "$ROOT"
mount "${LOOP}p1" "$ROOT/boot/firmware"
for m in dev dev/pts proc sys; do mount --bind "/$m" "$ROOT/$m"; done
cp /etc/resolv.conf "$ROOT/etc/resolv.conf.jarvis"
mount --bind /etc/resolv.conf "$ROOT/etc/resolv.conf" 2>/dev/null || true

echo "== Installing what Jarvis needs (in an emulated Pi)"
chroot "$ROOT" /bin/bash -euo pipefail <<'CHROOT'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends alsa-utils python3 curl iw rfkill >/dev/null
apt-get clean
rm -rf /var/lib/apt/lists/*
CHROOT
umount "$ROOT/etc/resolv.conf" 2>/dev/null || true
rm -f "$ROOT/etc/resolv.conf.jarvis"

echo "== Adding Jarvis"
install -d -m 755 "$ROOT/opt/jarvis-voice"
python3 - "$HERE/../jarvis-voice/hub.py" "$ROOT/opt/jarvis-voice/jarvis-pi.py" <<'PY'
import ast, sys
tree = ast.parse(open(sys.argv[1]).read())
for node in tree.body:
    if isinstance(node, ast.Assign) and any(getattr(t, "id", "") == "PI_CLIENT" for t in node.targets):
        open(sys.argv[2], "w").write(node.value.value)
        break
else:
    sys.exit("PI_CLIENT not found in hub.py")
PY
chmod 755 "$ROOT/opt/jarvis-voice/jarvis-pi.py"
python3 -m py_compile "$ROOT/opt/jarvis-voice/jarvis-pi.py"
install -m 755 "$HERE/files/jarvis-firstboot.sh" "$ROOT/usr/local/sbin/jarvis-setup"
install -m 755 "$HERE/files/jarvis-audio.sh" "$ROOT/usr/local/sbin/jarvis-audio"
install -m 755 "$HERE/files/jarvis-update-client.sh" "$ROOT/usr/local/sbin/jarvis-update-client"
install -m 644 "$HERE/files/jarvis-setup.service" "$ROOT/etc/systemd/system/jarvis-setup.service"
install -m 644 "$HERE/files/jarvis-voice.service" "$ROOT/etc/systemd/system/jarvis-voice.service"
install -m 644 "$HERE/files/jarvis.txt" "$ROOT/boot/firmware/jarvis.txt"
cat > "$ROOT/boot/firmware/README-JARVIS.txt" <<'TXT'
Open jarvis.txt (on this drive), fill in your Wi-Fi, your NAS's address and the jarvis-voice key, save,
eject the card and put it in the Pi with the USB speakerphone plugged in. After a few minutes Jarvis says
it's listening. Then say "Hey Jarvis".
TXT

chroot "$ROOT" /bin/bash -euo pipefail <<'CHROOT'
systemctl enable jarvis-setup.service jarvis-voice.service ssh.service >/dev/null 2>&1
# jarvis.txt makes the login, so skip the first-boot "create a user" prompt.
systemctl mask userconfig.service >/dev/null 2>&1 || true
# Debian's default would otherwise open a console wizard asking for a keyboard layout.
rm -f /etc/systemd/system/multi-user.target.wants/piwiz.service 2>/dev/null || true
CHROOT
# No accounts with known passwords.
sed -i -E 's/^pi:[^:]*:/pi:*:/' "$ROOT/etc/shadow" 2>/dev/null || true

echo "== Checking"
chroot "$ROOT" /usr/bin/python3 -m py_compile /opt/jarvis-voice/jarvis-pi.py
chroot "$ROOT" /bin/bash -n /usr/local/sbin/jarvis-setup
chroot "$ROOT" /usr/bin/which arecord aplay amixer curl >/dev/null
chroot "$ROOT" systemctl is-enabled jarvis-setup.service jarvis-voice.service ssh.service

echo "== Packing"
cleanup
trap - EXIT
rm -f jarvis-pi.img.xz
xz -T0 -6 -k jarvis-pi.img
sha256sum jarvis-pi.img.xz > jarvis-pi.img.xz.sha256
ls -lh jarvis-pi.img.xz
