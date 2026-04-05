#!/usr/bin/env bash
# Install KVM + libvirt + virt-manager on Arch/CachyOS, then optionally define a Win11 VM
# from an existing disk image (qcow2/raw). Run once with sudo-root via: bash setup-win11-libvirt.sh
#
# Usage:
#   ./setup-win11-libvirt.sh                    # host packages + libvirt only
#   WIN_DISK=/path/to/disk.qcow2 ./setup-win11-libvirt.sh   # also create VM "win11"
#
# After install: log out and back in (or newgrp) so group libvirt,kvm applies.
# Manage: virt-manager, or: virsh start win11 && virt-viewer win11
#
# If your Windows lives in .vhdx or .vdi, convert first, e.g.:
#   qemu-img convert -p -O qcow2 Win11.vhdx Win11.qcow2

set -euo pipefail

DISK=${WIN_DISK:-}
VM_NAME=${WIN_VM_NAME:-win11}
RAM_MB=${WIN_RAM_MB:-8192}
VCPUS=${WIN_VCPUS:-4}

need_root() {
  if [[ ${EUID:-0} -ne 0 ]]; then
    echo "Re-run as root, e.g.: sudo $0" >&2
    exit 1
  fi
}

install_host() {
  # qemu-desktop: spice UI, sound, etc. for virt-manager
  pacman -Sy --needed --noconfirm \
    qemu-desktop libvirt virt-manager virt-viewer edk2-ovmf dnsmasq iptables-nft swtpm
  systemctl enable --now libvirtd.service
  # typical default network "default" for NAT
  virsh net-autostart default 2>/dev/null || true
}

add_groups() {
  local u=${SUDO_USER:-}
  [[ -n $u ]] || return 0
  usermod -aG libvirt,kvm "$u"
  echo "Added $u to libvirt,kvm — re-login (or: newgrp libvirt) before using virt-manager."
}

create_vm_import() {
  local path=$1
  if [[ ! -f $path && ! -b $path ]]; then
    echo "WIN_DISK not found: $path" >&2
    exit 1
  fi
  if virsh dominfo "$VM_NAME" &>/dev/null; then
    echo "Domain $VM_NAME already exists; remove with: virsh undefine --remove-all-storage $VM_NAME" >&2
    exit 1
  fi
  # SATA is safest if the disk came from bare metal or another hypervisor without virtio storage drivers.
  virt-install \
    --name "$VM_NAME" \
    --memory "$RAM_MB" \
    --vcpus "$VCPUS" \
    --disk "path=${path},bus=sata" \
    --import \
    --os-variant win11 \
    --network network=default \
    --boot uefi \
    --tpm backend.type=emulator,backend.version=2.0 \
    --graphics spice,listen=127.0.0.1 \
    --noautoconsole
  echo "Created $VM_NAME. Start: virsh start $VM_NAME && virt-viewer $VM_NAME"
  echo "Or use: virt-manager"
  echo "If the VM cannot open the disk, move it under /var/lib/libvirt/images/ or fix perms for user qemu (see Arch wiki: libvirt/QEMU)."
}

need_root
install_host
add_groups

if [[ -n $DISK ]]; then
  create_vm_import "$DISK"
else
  echo "Host ready. Create a VM in virt-manager (UEFI + TPM emulator), or re-run with WIN_DISK=/path/to/Win11.qcow2"
fi
