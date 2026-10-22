# Week 12 box 3: one EC2 backend host and one JMeter host in the same AZ of the
# default VPC. Region ap-southeast-2 and only the six Free-plan instance types
# (t3.micro/t3.small/t4g.micro/t4g.small/c7i-flex.large/m7i-flex.large); no NAT
# gateway, no Elastic IP, no load balancer, no RDS/ElastiCache/Amazon MQ, no
# IAM resources created here.

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project = "flash-sale"
    }
  }
}

# ---------------------------------------------------------------------------
# Data sources (read-only)
# ---------------------------------------------------------------------------

# Existing instance profile created by hand by the owner. Referenced as a data
# source; never created (DS never creates IAM resources in Terraform).
data "aws_iam_instance_profile" "ssm" {
  name = "flashsale-ec2-ssm"
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet" "default" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = var.availability_zone
  default_for_az    = true
}

# Amazon Linux 2023, x86_64, from the public SSM parameter.
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------

# JMeter: no ingress; egress open (talks to the backend and pulls nothing but
# JMeter was installed at boot).
resource "aws_security_group" "jmeter" {
  name        = "${var.name_prefix}-jmeter"
  description = "JMeter load generator: no ingress, egress open"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-jmeter"
  }
}

# Backend: ingress only TCP 80 from the JMeter security group; no SSH, no
# 0.0.0.0/0 ingress at all. Egress open (pull images, reach AWS endpoints).
resource "aws_security_group" "backend" {
  name        = "${var.name_prefix}-backend"
  description = "Backend: ingress only TCP 80 from the JMeter SG, egress open"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "API from the JMeter host (Nginx on port 80)"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.jmeter.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-backend"
  }
}

# ---------------------------------------------------------------------------
# Backend instance (Docker + Compose, all services)
# ---------------------------------------------------------------------------
resource "aws_instance" "backend" {
  ami           = data.aws_ssm_parameter.al2023_ami.value
  instance_type = var.backend_instance_type

  subnet_id              = data.aws_subnet.default.id
  vpc_security_group_ids = [aws_security_group.backend.id]
  iam_instance_profile   = data.aws_iam_instance_profile.ssm.name

  # Public IPv4 on launch is allowed: the host must pull Docker images and reach
  # AWS endpoints. There is no NAT gateway and no Elastic IP by design.
  associate_public_ip_address = true

  # Safety net for a forgotten session: the user_data schedules a self-shutdown
  # after var.auto_terminate_minutes, and AWS terminates the instance when it
  # powers off. terraform destroy is still the normal cleanup; the security
  # groups remain until destroy.
  instance_initiated_shutdown_behavior = "terminate"

  # t3/t4g use standard (burstable) credits; not valid for m7i-flex/c7i-flex,
  # so the block is added only for t3/t4g instance types.
  dynamic "credit_specification" {
    for_each = (startswith(var.backend_instance_type, "t3") || startswith(var.backend_instance_type, "t4g")) ? [1] : []
    content {
      cpu_credits = "standard"
    }
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_tokens = "required"
  }

  # Install Docker + the Compose plugin (pinned). No secrets here.
  user_data = <<-EOT
    #!/bin/bash
    set -euxo pipefail
    # Schedule self-shutdown as a safety net before anything that can fail; it
    # returns at once and AWS terminates the instance when it powers off.
    shutdown -h +${var.auto_terminate_minutes}
    dnf update -y
    dnf install -y docker
    systemctl enable --now docker
    usermod -aG docker ec2-user
    DOCKER_COMPOSE_VERSION=v2.29.7
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -fsSL "https://github.com/docker/compose/releases/download/$${DOCKER_COMPOSE_VERSION}/docker-compose-linux-x86_64" \
      -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
    docker --version
    docker compose version
  EOT

  tags = {
    Name = "${var.name_prefix}-backend"
  }
}

# ---------------------------------------------------------------------------
# JMeter instance (load generator)
# ---------------------------------------------------------------------------
resource "aws_instance" "jmeter" {
  ami           = data.aws_ssm_parameter.al2023_ami.value
  instance_type = var.jmeter_instance_type

  subnet_id              = data.aws_subnet.default.id
  vpc_security_group_ids = [aws_security_group.jmeter.id]
  iam_instance_profile   = data.aws_iam_instance_profile.ssm.name

  associate_public_ip_address = true

  # Safety net for a forgotten session: the user_data schedules a self-shutdown
  # after var.auto_terminate_minutes, and AWS terminates the instance when it
  # powers off. terraform destroy is still the normal cleanup; the security
  # groups remain until destroy.
  instance_initiated_shutdown_behavior = "terminate"

  dynamic "credit_specification" {
    for_each = (startswith(var.jmeter_instance_type, "t3") || startswith(var.jmeter_instance_type, "t4g")) ? [1] : []
    content {
      cpu_credits = "standard"
    }
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_tokens = "required"
  }

  # Install Java + Apache JMeter at the same pinned version the repo uses
  # (D:\tools\apache-jmeter-5.6.3). No secrets here.
  user_data = <<-EOT
    #!/bin/bash
    set -euxo pipefail
    # Schedule self-shutdown as a safety net before anything that can fail; it
    # returns at once and AWS terminates the instance when it powers off.
    shutdown -h +${var.auto_terminate_minutes}
    dnf update -y
    dnf install -y java-17-amazon-corretto-headless tar gzip
    JMETER_VERSION=5.6.3
    curl -fsSL "https://archive.apache.org/dist/jmeter/binaries/apache-jmeter-$${JMETER_VERSION}.tgz" -o /opt/apache-jmeter.tgz
    tar -xzf /opt/apache-jmeter.tgz -C /opt
    ln -s "/opt/apache-jmeter-$${JMETER_VERSION}" /opt/jmeter
    rm -f /opt/apache-jmeter.tgz
    /opt/jmeter/bin/jmeter --version
  EOT

  tags = {
    Name = "${var.name_prefix}-jmeter"
  }
}
