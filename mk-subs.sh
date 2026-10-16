#!/bin/sh

Usage="$0 VMID [host-name] [disk-storage] [iso-storage] [iso-name] [,tag=vlan]"

VMID=${1?${Usage}}
HOST=${2?${Usage}}
STORE=${3-"local-zfs"}
ISO=${4-"proxmox:iso"}
ISO=${5-"${ISO}/guix-system-install-1.5.0.x86_64-linux.iso"}
VLAN=${6}

qm create $VMID --name ${HOST} --ostype l26 \
  --machine q35 --bios seabios --cpu host --cores 16 \
  --memory 32768 --balloon 0 \
  --scsihw virtio-scsi-single \
  --scsi0 ${STORE}:400,discard=on,iothread=1,ssd=1 \
  --net0 virtio,bridge=vmbr0${VLAN} \
  --ide2 ${ISO},media=cdrom \
  --boot 'order=scsi0;ide2' \
  --serial0 socket --agent enabled=1
qm start ${VMID}
