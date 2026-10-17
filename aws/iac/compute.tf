# Latest Ubuntu 24.04 image, looked up through Canonical's public SSM parameter.
data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# SSH key pair generated here. The private key is written next to the Terraform files
# (git-ignored) and also lives in the Terraform state, so protect both.
resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "main" {
  key_name   = "todo-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "local_sensitive_file" "ssh_key" {
  content         = tls_private_key.ssh.private_key_openssh
  filename        = var.ssh_key_path
  file_permission = "0600"
}

locals {
  # Runs once, as root, when the instance first boots. The marker file at the end
  # lets the pipeline wait until the host is ready.
  bootstrap = <<-EOT
    #!/bin/bash
    set -euxo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y docker.io docker-compose-v2 curl unzip jq
    systemctl enable --now docker
    usermod -aG docker ubuntu
    curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip
    unzip -q /tmp/awscliv2.zip -d /tmp
    /tmp/aws/install
    mkdir -p /home/ubuntu/todo
    chown ubuntu:ubuntu /home/ubuntu/todo
    touch /var/lib/todo-bootstrap-done
  EOT
}

resource "aws_instance" "app" {
  ami                         = data.aws_ssm_parameter.ubuntu.value
  instance_type               = var.app_instance_type
  subnet_id                   = aws_subnet.app.id
  vpc_security_group_ids      = [aws_security_group.app.id]
  key_name                    = aws_key_pair.main.key_name
  iam_instance_profile        = aws_iam_instance_profile.app.name
  user_data                   = local.bootstrap
  user_data_replace_on_change = true

  # IMDSv2 only. aws/deploy.sh already uses token-based metadata requests.
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  tags       = { Name = "todo-app" }
  depends_on = [aws_route_table_association.app]
}

resource "aws_instance" "ops" {
  ami                         = data.aws_ssm_parameter.ubuntu.value
  instance_type               = var.ops_instance_type
  subnet_id                   = aws_subnet.ops.id
  vpc_security_group_ids      = [aws_security_group.ops.id]
  key_name                    = aws_key_pair.main.key_name
  user_data                   = local.bootstrap
  user_data_replace_on_change = true

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  tags       = { Name = "todo-ops" }
  depends_on = [aws_route_table_association.ops]
}
