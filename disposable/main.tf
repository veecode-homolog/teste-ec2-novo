### DATA IMPORT

data "aws_vpc" "selected" {
  id = local.config.VPC_ID
}

data "aws_subnet" "selected" {
  id = local.config.SUBNET_ID
}

data "aws_ami" "amazon-linux" {
  most_recent = true

  filter {
    name   = "owner-alias"
    values = ["amazon"]
  }

  filter {
    name   = "name"
    # values = ["amzn2-ami-hvm-*-x86_64-ebs"]
    values = ["al2023-ami-*-x86_64"]
  }
}

### REDE

data "aws_security_group" "web_security_group" {
  name = "access_cluster_SG"
}

data "aws_efs_file_system" "efs-platform" {
  creation_token = "platform-efs"
}

resource "aws_instance" "platform-vm" {
  ami             = data.aws_ami.amazon-linux.id
  key_name        = local.config.keypar
  security_groups = [data.aws_security_group.web_security_group.id]
  instance_type   = local.config.instance_type
  subnet_id       = data.aws_subnet.selected.id
  user_data = <<EOF
#!/bin/bash
sudo yum update && sudo yum upgrade
sudo yum install -y curl-minimal wget openssl git unzip docker sed
sudo service docker start && sudo systemctl enable docker.service
sudo usermod -a -G docker ec2-user && newgrp docker
wget -q -O - https://raw.githubusercontent.com/rancher/k3d/main/install.sh | bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
curl -O https://s3.us-west-2.amazonaws.com/amazon-eks/1.27.7/2023-11-02/bin/linux/amd64/kubectl
chmod +x ./kubectl && mkdir -p $HOME/bin && cp ./kubectl $HOME/bin/kubectl && export PATH=$HOME/bin:$PATH
k3d cluster create k3s --servers 1 -p "80:80@loadbalancer" -p "443:443@loadbalancer" --api-port 6550  --k3s-arg "--disable=traefik@server:*" --kubeconfig-update-default

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add metallb https://metallb.github.io/metallb
helm repo add cert-manager https://charts.jetstack.io
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx
helm install metallb metallb/metallb --create-namespace -n metallb-system
helm install cert-manager cert-manager/cert-manager --create-namespace --namespace cert-manager --version v1.14.4
kubectl apply -f "https://github.com/jetstack/cert-manager/releases/download/v1.14.4/cert-manager.crds.yaml"
kubectl create namespace lfr-stack

echo "
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: teste@vertigo.com.br
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          ingress:
            class: nginx
" | kubectl apply -f -

export TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
export EC2_PUBLIC_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)
echo "IP_EC2 = $EC2_PUBLIC_IP"

echo "
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: first-pool
  namespace: metallb-system
spec:
  addresses:
    - $EC2_PUBLIC_IP/32
" | kubectl apply -f -

mkdir /home/ec2-user/.kube && k3d kubeconfig get k3s > /home/ec2-user/.kube/config

EOF

  root_block_device {
    volume_size = local.config.volume_size
  }

  tags = {
    Name = local.config.cluster_name
  }
}

data "aws_eip" "webip" {
  filter {
    name   = "tag:Name"
    values = ["platform-eip"]
  }
}

resource "aws_eip_association" "eip_assoc" {
  instance_id   = aws_instance.platform-vm.id
  allocation_id = data.aws_eip.webip.id
}
