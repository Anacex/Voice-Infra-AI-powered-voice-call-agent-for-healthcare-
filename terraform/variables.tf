variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "instance_type" {
  type        = string
  default     = "t3.medium" # 2 vCPU / 4GB — enough for backend+postgres+prometheus+grafana at this scale
  description = "Bump to t3.large if Grafana/Prometheus feel sluggish alongside Postgres"
}

variable "ssh_key_name" {
  type        = string
  description = "Name of an existing EC2 key pair for SSH access"
}

variable "ssh_allowed_cidr" {
  type        = string
  description = "Your IP in CIDR form (e.g. 1.2.3.4/32) — never leave this as 0.0.0.0/0"
}

variable "domain" {
  type        = string
  description = "The real domain provided by the company, e.g. candidate-name.stratus-eval.dev"
}

variable "repo_url" {
  type        = string
  description = "HTTPS URL of this repo, e.g. https://github.com/<you>/voice-infra.git"
}

variable "server_monitor_repo_url" {
  type        = string
  description = "HTTPS URL of the server-monitor sibling repo (cloned as a peer of this repo on the host)"
  default     = ""
}

variable "log_collector_repo_url" {
  type        = string
  description = "HTTPS URL of the log-collector sibling repo (cloned as a peer of this repo on the host)"
  default     = ""
}

variable "pg_password" {
  type      = string
  sensitive = true
}

variable "grafana_admin_password" {
  type      = string
  sensitive = true
}

variable "vapi_webhook_secret" {
  type      = string
  sensitive = true
  default   = ""
}

variable "vapi_api_key" {
  type      = string
  sensitive = true
  default   = ""
}

variable "discord_webhook_url" {
  type      = string
  sensitive = true
  default   = ""
}
