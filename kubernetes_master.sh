#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] Kubernetes control-plane provisioning started..."

MASTER_IP="192.168.79.131"
POD_CIDR="10.244.0.0/16"
K8S_VERSION="v1.29.15"
KUBEADM_API_VERSION="kubeadm.k8s.io/v1beta3"

echo "[INFO] Updating packages..."
dnf -y update

echo "[INFO] Setting hostname..."
hostnamectl set-hostname master-node

echo "[INFO] Ensuring /etc/hosts entries..."
for entry in \
	"192.168.79.131 master-node" \
	"192.168.79.134 node-1 worker-node-1" \
	"192.168.79.136 node-2 worker-node-2"; do
	grep -qF "$entry" /etc/hosts || echo "$entry" >> /etc/hosts
done

echo "[INFO] Configuring Kubernetes repository (${K8S_VERSION})..."
cat > /etc/yum.repos.d/kubernetes.repo <<'EOF'
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/repodata/repomd.xml.key
EOF

echo "[INFO] Hardening SSH config (disable password auth)..."
if grep -q '^#\?PasswordAuthentication' /etc/ssh/sshd_config; then
	sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
else
	echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
fi
if grep -q '^#\?PermitRootLogin' /etc/ssh/sshd_config; then
	sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
else
	echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config
fi
systemctl restart sshd

echo "[INFO] Configuring SELinux and swap..."
setenforce 0 || true
sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
swapoff -a
sed -ri 's@^([^#].*\sswap\s+.*)$@#\1@' /etc/fstab

echo "[INFO] Loading kernel modules and sysctl params for Kubernetes networking..."
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/99-kubernetes-cri.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system

echo "[INFO] Configuring container runtime sources..."
dnf install -y dnf-plugins-core
dnf config-manager --add-repo=https://download.docker.com/linux/centos/docker-ce.repo
dnf -y module reset container-tools || true

echo "[INFO] Resolving container runtime package prerequisites..."
dnf install -y container-selinux

echo "[INFO] Installing container runtime and Kubernetes components..."
dnf install -y --allowerasing --nobest containerd.io
dnf install -y kubelet kubeadm kubectl firewalld

echo "[INFO] Configuring containerd (SystemdCgroup=true)..."
mkdir -p /etc/containerd
if [ ! -f /etc/containerd/config.toml ]; then
	containerd config default > /etc/containerd/config.toml
fi

# Ensure CRI plugin is enabled (required by kubelet/kubeadm)
sed -i '/^disabled_plugins *=/d' /etc/containerd/config.toml

# Ensure kubelet-compatible cgroup driver
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

echo "[INFO] Enabling services..."
systemctl daemon-reload
systemctl enable --now containerd
systemctl restart containerd
systemctl enable --now kubelet
systemctl enable --now firewalld

echo "[INFO] Configuring firewall for Kubernetes control plane..."
firewall-cmd --permanent --add-port=6443/tcp
firewall-cmd --permanent --add-port=2379-2380/tcp
firewall-cmd --permanent --add-port=10250/tcp
firewall-cmd --permanent --add-port=10257/tcp
firewall-cmd --permanent --add-port=10259/tcp
firewall-cmd --permanent --add-port=30000-32767/tcp
firewall-cmd --permanent --add-port=8472/udp                              # Flannel VXLAN
firewall-cmd --permanent --zone=trusted --add-source=10.244.0.0/16        # pod network
firewall-cmd --permanent --zone=public --add-masquerade
firewall-cmd --reload

echo "[INFO] Writing kubeadm config with long certificate validity..."
cat > /root/kubeadm-config.yaml <<EOF
apiVersion: ${KUBEADM_API_VERSION}
kind: ClusterConfiguration
kubernetesVersion: ${K8S_VERSION}
controlPlaneEndpoint: "${MASTER_IP}:6443"
networking:
  podSubnet: "${POD_CIDR}"
apiServer:
  certSANs:
    - "${MASTER_IP}"
    - "master-node"
---
apiVersion: ${KUBEADM_API_VERSION}
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "${MASTER_IP}"
  bindPort: 6443
nodeRegistration:
  name: master-node
  criSocket: "unix:///run/containerd/containerd.sock"
EOF

if [ ! -f /etc/kubernetes/admin.conf ]; then
	echo "[INFO] Initializing Kubernetes control plane..."
	kubeadm init --config /root/kubeadm-config.yaml --upload-certs
else
	echo "[INFO] Kubernetes already initialized; skipping kubeadm init."
fi

echo "[INFO] Configuring kubeconfig for root and vagrant user..."
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config

if id vagrant >/dev/null 2>&1; then
	mkdir -p /home/vagrant/.kube
	cp -f /etc/kubernetes/admin.conf /home/vagrant/.kube/config
	chown -R vagrant:vagrant /home/vagrant/.kube
fi

echo "[INFO] Installing Flannel CNI..."
KUBECONFIG=/etc/kubernetes/admin.conf kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

echo "[INFO] Generating join command for worker nodes..."
kubeadm token create --print-join-command > /root/kubeadm-join-command.sh
chmod 700 /root/kubeadm-join-command.sh

echo "[INFO] Installing Kubernetes cert auto-renew checker..."
if [ ! -f /vagrant/k8s-cert-renew.sh ]; then
	echo "[ERROR] /vagrant/k8s-cert-renew.sh not found"
	exit 1
fi
install -m 755 /vagrant/k8s-cert-renew.sh /usr/local/bin/k8s-cert-renew.sh

cat > /etc/systemd/system/k8s-cert-renew.service <<'EOF'
[Unit]
Description=Kubernetes certificate renewal check
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/k8s-cert-renew.sh
EOF

cat > /etc/systemd/system/k8s-cert-renew.timer <<'EOF'
[Unit]
Description=Daily Kubernetes certificate renewal check

[Timer]
OnBootSec=2min
OnUnitActiveSec=24h
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now k8s-cert-renew.timer

echo "[INFO] Master node is ready."