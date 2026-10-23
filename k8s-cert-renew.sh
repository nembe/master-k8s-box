#!/usr/bin/env bash
set -euo pipefail

# Renew when any leaf cert has fewer than this many days remaining.
THRESHOLD_DAYS="${THRESHOLD_DAYS:-45}"
KUBECONFIG=/etc/kubernetes/admin.conf

if [ ! -f /etc/kubernetes/admin.conf ]; then
  echo "[cert-renew] admin.conf not found, skipping"
  exit 0
fi

output="$(kubeadm certs check-expiration 2>/dev/null || true)"
if [ -z "$output" ]; then
  echo "[cert-renew] unable to read certificate expiration"
  exit 1
fi

min_days="$({
  echo "$output" | awk '
  BEGIN{min=99999}
  /^[[:space:]]*(admin\.conf|apiserver|apiserver-etcd-client|apiserver-kubelet-client|controller-manager\.conf|etcd-healthcheck-client|etcd-peer|etcd-server|front-proxy-client|scheduler\.conf|super-admin\.conf)[[:space:]]/ {
    if (match($0, /([0-9]+)d/, m)) {
      d=m[1]
      if (d < min) min=d
    }
  }
  END{if(min==99999) print ""; else print min}
  '
} || true)"

if [ -z "$min_days" ]; then
  echo "[cert-renew] could not determine minimum residual days"
  exit 1
fi

echo "[cert-renew] minimum leaf cert residual days: $min_days (threshold: $THRESHOLD_DAYS)"

if [ "$min_days" -le "$THRESHOLD_DAYS" ]; then
  echo "[cert-renew] renewing certificates..."
  kubeadm certs renew all
  systemctl restart kubelet
  echo "[cert-renew] renewal complete"
else
  echo "[cert-renew] renewal not needed"
fi
