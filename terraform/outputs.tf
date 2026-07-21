output "public_ip" {
  value       = aws_eip.voice_agent.public_ip
  description = "Point your domain's DNS A record at this IP"
}

output "ssh_command" {
  value = "ssh ubuntu@${aws_eip.voice_agent.public_ip}"
}

output "next_steps" {
  value = <<-EOT
    1. Point ${var.domain}'s DNS A record at ${aws_eip.voice_agent.public_ip}
    2. Wait for DNS propagation (check with: dig ${var.domain})
    3. SSH in and confirm cloud-init finished: ssh ubuntu@${aws_eip.voice_agent.public_ip} 'cat /var/log/cloud-init-output.log | tail -30'
    4. Caddy will auto-provision a TLS cert on first HTTPS request to the domain
    5. Update Vapi's serverUrl from the ngrok URL to https://${var.domain}/webhooks/vapi
       (re-run scripts/setup-vapi-agent.sh with DOMAIN=${var.domain} in .env on your local machine,
       or update it directly via the Vapi dashboard)
  EOT
}
