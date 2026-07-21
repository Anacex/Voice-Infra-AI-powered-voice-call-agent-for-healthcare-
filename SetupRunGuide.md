# Setup & Run Guide

Step-by-step instructions to stand up this project and test the voice agent,
either locally or on real cloud infrastructure via Terraform. See
[`README.md`](./README.md) for architecture, trade-offs, and the honest
status of the observability integration.

---

## Option A — Run locally (fastest way to verify everything works)

### Prerequisites
- Docker + Docker Compose v2
- `git`, `curl`, `jq`
- A Vapi account (free) — https://vapi.ai
- (Optional but recommended) `ngrok` if you want to actually call the agent
  from a real phone while running locally

### 1. Clone this repo and the two sibling observability repos

```bash
git clone <this-repo-url> voice-infra
git clone https://github.com/Anacex/server-monitoring-discord-alerts-service.git server-monitor
git clone https://github.com/Anacex/Log-collector-telemetry.git log-collector
```

Clone all three **as sibling directories** (same parent folder) — `docker-compose.yml`
in `voice-infra/` references `../server-monitor` by relative path.

```
some-folder/
├── voice-infra/       <- this repo, you'll run commands from here
├── server-monitor/
└── log-collector/
```

### 2. Configure environment

```bash
cd voice-infra
cp .env.example .env
```

Edit `.env`:
```
DOMAIN=localhost
PG_PASSWORD=localdevpassword
GRAFANA_ADMIN_PASSWORD=localdevpassword
VAPI_WEBHOOK_SECRET=
VAPI_API_KEY=              # from Vapi dashboard -> Settings -> API Keys (private key)
DISCORD_WEBHOOK_URL=       # optional — leave blank if you don't want alerts delivered anywhere
```

### 3. Render the alertmanager config

```bash
chmod +x scripts/render-alertmanager-config.sh
./scripts/render-alertmanager-config.sh
```

### 4. Bring up the main stack (local override skips Caddy/TLS, exposes ports directly)

```bash
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d --build
```

This starts: `backend`, `postgres`, `prometheus`, `alertmanager`, `grafana`,
and `server-monitor`. (Caddy is skipped locally — it needs a real domain for
Let's Encrypt.)

### 5. (Optional) Bring up the log-collector stack too

```bash
cd ../log-collector
docker compose up -d --build
cd ../voice-infra
```

This runs its own Jaeger instance and demo services. See
"Pre-existing observability tooling" in `README.md` for what this does and
does not currently receive from the voice-agent backend.

### 6. Verify everything is healthy

```bash
curl http://localhost:8000/healthz
# expect: {"status":"ok","db":"up"}

docker compose ps
# expect all services "Up" / "healthy"
```

Check each dashboard in a browser:
| Service | URL |
|---|---|
| Backend health | http://localhost:8000/healthz |
| Backend calls API | http://localhost:8000/calls |
| Prometheus targets | http://localhost:9090/targets |
| Grafana (Voice Agent Operations dashboard) | http://localhost:3000 (admin / `GRAFANA_ADMIN_PASSWORD`) |
| Jaeger UI (if log-collector is running) | http://localhost:16686 |

### 7. Simulate a call end-to-end (no real phone needed)

```bash
chmod +x backend/simulate-call.sh
./backend/simulate-call.sh
curl -s http://localhost:8000/calls | jq .
curl -s http://localhost:8000/metrics | grep voice_
```

Confirm the simulated call shows up in the API response and the Grafana
dashboard's call-volume panel.

### 8. Test the backup/restore cycle

```bash
chmod +x backup/backup.sh backup/restore-test.sh
./backup/backup.sh
ls -la backup/backups/
./backup/restore-test.sh backup/backups/voiceagent_*.dump
```

Expect `[restore-test] PASSED — dump is restorable`.

### 9. (Optional) Actually call the agent from a real phone

1. Install ngrok, `ngrok config add-authtoken <token>`, then:
   ```bash
   ngrok http 8000
   ```
2. Copy the printed hostname (no `https://` prefix) into `.env`:
   ```
   DOMAIN=<your-ngrok-hostname>.ngrok-free.app
   ```
3. Create/update the Vapi assistant to point at it:
   ```bash
   chmod +x scripts/setup-vapi-agent.sh
   ./scripts/setup-vapi-agent.sh
   ```
4. In the Vapi dashboard, attach a phone number (imported from a Twilio
   trial account, or Vapi's own SIP/number offering — whatever's available
   at the time) to the assistant printed by the script above.
5. Call the number. Watch `docker compose logs -f backend` and
   `http://127.0.0.1:4040` (ngrok's local inspector) in real time.

---

## Option B — Deploy to real cloud infrastructure via Terraform

### Prerequisites
- Terraform >= 1.5
- AWS credentials with permission to create EC2 instances, security groups,
  and Elastic IPs (`aws configure`, or export `AWS_ACCESS_KEY_ID` /
  `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`)
- An existing EC2 key pair in the target region (for SSH access)
- A domain (or subdomain) you can point an A record at
- A Vapi account + API key

### 1. Push this repo to GitHub first
Terraform's `cloud-init.sh.tpl` clones this repo onto the new instance —
it needs a real, reachable git URL. Push your local work before applying.

### 2. Configure Terraform variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:
```hcl
ssh_key_name           = "your-ec2-keypair-name"
ssh_allowed_cidr        = "YOUR.IP.ADDRESS/32"   # find yours: curl -s ifconfig.me
domain                  = "candidate-name.stratus-eval.dev"
repo_url                = "https://github.com/<you>/voice-infra.git"
pg_password             = "<generate a strong random password>"
grafana_admin_password  = "<generate a strong random password>"
vapi_webhook_secret     = ""
vapi_api_key            = ""
discord_webhook_url     = ""
```

`terraform.tfvars` is gitignored — never commit it.

### 3. Apply

```bash
terraform init
terraform plan     # review what will be created: 1 EC2 instance, 1 security group, 1 Elastic IP
terraform apply    # type "yes" to confirm
```

This provisions an Ubuntu 24.04 EC2 instance whose boot script
(`cloud-init.sh.tpl`) automatically:
1. Installs Docker
2. Clones this repo, the `server-monitor` repo, and the `log-collector`
   repo as siblings on the instance (matching the local layout in Option A)
3. Writes `.env` from your Terraform variables
4. Renders the alertmanager config
5. Brings up the log-collector stack, then the main stack (backend,
   Postgres, Caddy, Prometheus, Alertmanager, Grafana, server-monitor)
6. Installs the nightly backup cron job

Takes a few minutes. Terraform prints the instance's public IP and next
steps when it finishes.

### 4. Point DNS at the new instance

Create an A record: `<your-domain>` → the `public_ip` Terraform printed.
Wait for propagation (`dig <your-domain>` should return that IP).

### 5. Verify cloud-init finished successfully

```bash
ssh ubuntu@<public_ip> 'tail -50 /var/log/cloud-init-output.log'
```

Look for `==> cloud-init complete` at the end with no errors above it.

### 6. Verify the stack is healthy on the real domain

```bash
curl https://<your-domain>/healthz
```

Caddy auto-provisions a Let's Encrypt TLS cert on first request — the very
first `curl` may take a few extra seconds while that happens.

```
https://<your-domain>/grafana/        # Grafana dashboards
https://<your-domain>/calls            # recent calls API
```

Jaeger UI is reachable at `http://<public_ip>:16686` (restricted by security
group to your IP only — Jaeger itself has no auth, so it's deliberately not
exposed publicly through Caddy).

### 7. Point Vapi at the real domain

On your local machine (not the server):
```bash
# update DOMAIN in your local .env to the real domain (no https:// prefix)
DOMAIN=<your-domain>

./scripts/setup-vapi-agent.sh
```

This re-creates/updates the Vapi assistant's `serverUrl` to point at the
real server instead of the ngrok tunnel used during local testing. Attach a
phone number to it in the Vapi dashboard as before.

### 8. Call the number

Same as local testing — call it, then check:
```bash
ssh ubuntu@<public_ip> 'cd /opt/voice-infra && docker compose logs -f backend'
```
or hit `https://<your-domain>/calls` to see it land in the database.

### 9. Tear down (when done evaluating)

```bash
cd terraform
terraform destroy
```

---

## Troubleshooting quick-reference

| Symptom | Likely cause | Fix |
|---|---|---|
| `docker compose up` fails mounting `alertmanager.yml` | You haven't run the render script yet, so Docker created a directory at that path instead of a file | `sudo rm -rf monitoring/prometheus/alertmanager.yml && ./scripts/render-alertmanager-config.sh` |
| All `.env` vars show as blank in compose warnings | `.env` doesn't exist or isn't in the same directory as `docker-compose.yml` | `cp .env.example .env` and fill it in |
| `server-monitor` build fails, path not found | Sibling repos not cloned, or cloned into the wrong location | Confirm `server-monitor/` and `log-collector/` sit next to `voice-infra/`, not inside it |
| Vapi webhook 400s with a JSON parse error | Stale `agent-config.json` rendering bug | Already fixed in `scripts/setup-vapi-agent.sh` (uses Python's JSON parser, not `grep`) — pull latest |
| `git push` rejected with 403 | Wrong GitHub account authenticated, or token missing `workflow` scope | Use a classic PAT with `repo` + `workflow` scopes, set via `git remote set-url` |
| Calls don't show up in Jaeger | Expected — the backend doesn't yet emit spans into the log-collector. See README "Pre-existing observability tooling" | Not a bug; documented integration gap |