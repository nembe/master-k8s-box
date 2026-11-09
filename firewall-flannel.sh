#!/usr/bin/env bash
# Configure firewalld so Flannel pod traffic can cross nodes.
# Run on every node: sudo ./firewall-flannel.sh [pod-cidr]
set -euo pipefail

POD_CIDR="${1:-10.244.0.0/16}"

if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] Run as root: sudo $0" >&2
  exit 1
fi

echo "[INFO] Configuring firewalld for Flannel (pod CIDR: $POD_CIDR)..."
firewall-cmd --permanent --zone=trusted --change-interface=flannel.1
firewall-cmd --permanent --zone=trusted --add-interface=cni0 || true   # already bound -> not fatal
firewall-cmd --permanent --zone=trusted --add-source="$POD_CIDR"
firewall-cmd --permanent --zone=public --add-masquerade
firewall-cmd --permanent --add-port=8472/udp
firewall-cmd --reload

echo "[INFO] Active zones:"
firewall-cmd --get-active-zones
echo "[INFO] Trusted zone:"
firewall-cmd --zone=trusted --list-all
