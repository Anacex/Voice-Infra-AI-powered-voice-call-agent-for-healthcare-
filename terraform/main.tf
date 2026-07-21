terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ---------------------------------------------------------------------------
# Single VPS-equivalent deployment on AWS, matching the docker-compose stack
# in the repo root. Deliberately not ECS/EKS — see README "Why this shape"
# section for the reasoning. This is the cloud-hosted version of the same
# architecture already validated locally.
# ---------------------------------------------------------------------------

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-noble-24.04-amd64-server-*"]
  }
}

resource "aws_security_group" "voice_agent" {
  name        = "voice-agent-sg"
  description = "Allow SSH (restricted), HTTP/HTTPS for Caddy/Let's Encrypt"

  ingress {
    description = "SSH from operator IP only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  ingress {
    description = "HTTP (Let's Encrypt ACME challenge + redirect)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS (Caddy reverse proxy - webhooks, calls API, Grafana)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "voice-agent-sg" }
}

resource "aws_instance" "voice_agent" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.ssh_key_name
  vpc_security_group_ids = [aws_security_group.voice_agent.id]

  root_block_device {
    volume_size = 40
    volume_type = "gp3"
    encrypted   = true # encrypts Postgres data at rest — flagged as a gap in README, closed here
  }

  # Bootstraps Docker + clones the repo + runs deploy.sh. Secrets are NOT
  # baked in here — they're written to .env on first boot from Terraform
  # variables marked sensitive, which come from a .tfvars file that is
  # itself gitignored (see terraform.tfvars.example).
  user_data = templatefile("${path.module}/cloud-init.sh.tpl", {
    domain                    = var.domain
    pg_password               = var.pg_password
    grafana_admin_password    = var.grafana_admin_password
    vapi_webhook_secret       = var.vapi_webhook_secret
    vapi_api_key              = var.vapi_api_key
    discord_webhook_url       = var.discord_webhook_url
    repo_url                  = var.repo_url
    server_monitor_repo_url   = var.server_monitor_repo_url
    log_collector_repo_url    = var.log_collector_repo_url
  })

  tags = { Name = "voice-agent-backend" }
}

resource "aws_eip" "voice_agent" {
  instance = aws_instance.voice_agent.id
  domain   = "vpc"
  tags     = { Name = "voice-agent-eip" }
}
