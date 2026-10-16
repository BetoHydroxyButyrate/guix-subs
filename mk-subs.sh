#!/bin/sh
# mk-subs.sh — on the Proxmox host: create and start the guix-subs VM,
# booting the Guix installer ISO. Then install with install.sh (README §2).
#
#   mk-subs.sh VMID [HOST] [DISK-STORAGE] [ISO-STORAGE] [ISO-NAME] [VLAN]
#
#   HOST          VM name                  (default guix-subs)
#   DISK-STORAGE  storage for the disk     (default local-zfs)
#   ISO-STORAGE   storage holding the ISO  (default proxmox:iso)
#   ISO-NAME      the installer ISO        (default guix-system-install-1.5.0.x86_64-linux.iso)
#   VLAN          VLAN tag, e.g. 30 (or ",tag=30"); none by default
#
# The VM boots the ISO first, so a reset during the install comes back to
# the installer. Detach the ISO once installed and it boots from the disk.
set -eu

usage="usage: $0 VMID [HOST] [DISK-STORAGE] [ISO-STORAGE] [ISO-NAME] [VLAN]"
[ $# -ge 1 ] || { echo "$usage" >&2; exit 1; }

vmid=$1
host=${2:-guix-subs}
store=${3:-local-zfs}
iso_store=${4:-proxmox:iso}
iso_name=${5:-guix-system-install-1.5.0.x86_64-linux.iso}
case ${6:-} in
    '')      vlan= ;;
    ,tag=*)  vlan=$6 ;;
    *)       vlan=,tag=$6 ;;
esac

qm create "$vmid" --name "$host" --ostype l26 \
  --machine q35 --bios seabios --cpu host --cores 16 \
  --memory 32768 --balloon 0 \
  --scsihw virtio-scsi-single \
  --scsi0 "$store:400,discard=on,iothread=1,ssd=1" \
  --net0 "virtio,bridge=vmbr0$vlan" \
  --ide2 "$iso_store/$iso_name,media=cdrom" \
  --boot 'order=ide2;scsi0' \
  --serial0 socket --agent enabled=1
qm start "$vmid"

ip=$(ip -4 -o addr show vmbr0 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4; exit}')
cat <<EOF

VM $vmid ($host) is booting the installer. Next:
  1. Here, in a checkout of guix-subs with etc/guix-subs/beto-ssh.pub added:
       python3 -m http.server 8000
  2. In the VM's console, non-graphical install, then a shell:
       wget http://${ip:-THIS-HOST}:8000/install.sh
       sh install.sh http://${ip:-THIS-HOST}:8000
  3. Then:  qm set $vmid --ide2 none,media=cdrom   and reboot the VM.
EOF
