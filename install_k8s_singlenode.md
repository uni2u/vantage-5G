# Installing Kubernetes Single-Node Setup on Ubuntu 24.04

## 1. Prepare the Ubuntu
- Update system packages:
```
sudo apt update && sudo apt upgrade -y
```
- Disable swap (Kubernetes requires this):
```
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab
```

## 2. Enable Kernel Modules and Sysctl Settings
```
sudo modprobe overlay
sudo modprobe br_netfilter

sudo tee /etc/sysctl.d/kubernetes.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

sudo sysctl --system
```

## 3. Install Docker or Containerd (Container Runtime)
- install docker
```
sudo apt install -y docker.io
sudo systemctl enable docker
sudo systemctl start docker
```
- install containerd
```
sudo apt install -y containerd

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml

# Enable systemd cgroup
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

sudo nano /etc/containerd/config.toml
```

Search

>> [plugins."io.containerd.grpc.v1.cri"]
>> and then,

```
sandbox_image = "registry.k8s.io/pause:3.10"

sudo systemctl restart containerd
sudo systemctl enable containerd
```

## 4. Add the Kubernetes APT Repository
```
sudo apt install -y apt-transport-https ca-certificates curl gpg
sudo mkdir -p /etc/apt/keyrings

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key | \
sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /" | \
sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt update
```

## 5. Install Kubernetes Tools: kubeadm, kubelet, kubectl
```
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

## 6. Install Helm
```
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

or

curl -LO https://get.helm.sh/helm-v3.17.3-linux-amd64.tar.gz
tar -zxvf helm-v3.17.3-linux-amd64.tar.gz
sudo mv linux-amd64/helm /usr/local/bin/helm
rm -rf helm-v3.17.3-linux-amd64.tar.gz
```

check
```
helm version

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

## 7. Initialize the Kubernetes Control Plane
```
sudo kubeadm init --pod-network-cidr=10.0.0.0/16
```

## 8. Set up kubeconfig:
```
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

## 9. Check Node Status
```
kubectl get nodes
```

## 10. Install cilium-cli
```
curl -L --remote-name https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz
sudo tar xzvf cilium-linux-amd64.tar.gz -C /usr/local/bin
rm cilium-linux-amd64.tar.gz
```

## 11. Install Cilium
```
cilium install
```

## 12. Check Node Status and Cilium Status
```
kubectl get nodes
cilium status
```
