#!/bin/sh
# install.sh — install guix-subs from the Guix installer's shell, without
# the graphical installer. Boot the installer ISO, choose the non-graphical
# install, open a shell (the network comes up on its own), then:
#
#   wget http://SERVER:8000/install.sh
#   sh install.sh http://SERVER:8000 [DISK]
#
# where SERVER serves a checkout of this repository, with your SSH public
# key added as etc/guix-subs/beto-ssh.pub; for example, on the Proxmox host:
#   cd guix-subs && python3 -m http.server 8000
#
# It WIPES DISK (default /dev/sda): a GPT label with a BIOS boot partition
# and an ext4 root labelled guix-root, as config.scm expects. Then it
# copies etc/guix-subs to /etc/guix-subs on the new system and runs
# 'guix system init' with config.scm, so the first boot is the final system.
set -eu

die() { echo "install.sh: $*" >&2; exit 1; }

src=${1:-}
disk=${2:-/dev/sda}
[ -n "$src" ] || die "usage: sh install.sh http://SERVER:PORT [DISK]"
src=${src%/}
files="config.scm build-qubes.sh install-cert.sh template.scm packages beto-ssh.pub"

[ "$(id -u)" = 0 ] || die "run as root (the installer's shell is root)"
[ -b "$disk" ] || die "$disk: no such disk"
case $disk in
    *[0-9]) part=${disk}p ;;       # /dev/nvme0n1 -> /dev/nvme0n1p2
    *)      part=$disk ;;          # /dev/sda     -> /dev/sda2
esac
if ls "$part"[0-9]* >/dev/null 2>&1 && [ "${FORCE:-}" != 1 ]; then
    die "$disk already has partitions; run with FORCE=1 to wipe it"
fi

echo "== fetching files from $src"
# Not under /tmp: cow-store mounts the new system's /tmp over it.
tmp=/run/guix-subs
rm -rf "$tmp" && mkdir -p "$tmp"
for f in $files; do
    wget -q -O "$tmp/$f" "$src/etc/guix-subs/$f" || die "couldn't fetch $f"
done
grep -q '^ssh-' "$tmp/beto-ssh.pub" ||
    die "beto-ssh.pub doesn't look like an SSH public key"
chmod +x "$tmp/build-qubes.sh"

# Release what we safely can: /mnt and swap on the disk. If an earlier
# run started cow-store, the disk stays busy (it holds the installer's
# /tmp and the store overlay), and only a fresh boot of the installer
# frees it.
umount -R /mnt 2>/dev/null || true
for p in "$part"[0-9]*; do
    [ -b "$p" ] || continue
    swapoff "$p" 2>/dev/null || true
    if grep -q "^$p " /proc/mounts; then
        die "$p is still in use (an earlier run?): reboot the installer and run this again"
    fi
done

echo "== partitioning $disk (everything on it is lost)"
wipefs -q -a "$disk"
parted -s "$disk" -- mklabel gpt \
    mkpart grub 1MiB 3MiB set 1 bios_grub on \
    mkpart root ext4 3MiB 100%
command -v udevadm >/dev/null && udevadm settle
sleep 1
mkfs.ext4 -q -F -L guix-root "${part}2"

echo "== installing"
mount "${part}2" /mnt
# The store being built lives on the target disk, not in the installer's RAM.
mkdir -p /mnt/etc/guix-subs
cp -p "$tmp"/* /mnt/etc/guix-subs/
herd start cow-store /mnt
guix system init /mnt/etc/guix-subs/config.scm /mnt

echo "== done: detach the ISO in Proxmox, then reboot"
