# Voice Agent Infrastructure — Lakewood Family Medicine (demo)

Operational infrastructure for an AI voice receptionist handling patient calls
(scheduling, refill requests, routing). Built for the DevOps/Infrastructure
take-home challenge.

**Repo layout:**
```
backend/          FastAPI service — Vapi webhook receiver, call persistence, /metrics
docker-compose.yml   Full stack: backend, postgres, caddy (TLS), prometheus, alertmanager, grafana, server-monitor
caddy/             Reverse proxy + automatic TLS config
monitoring/        Prometheus scrape config, alert rules, Grafana dashboards
backup/            pg_dump backup script, restore-test script, cron schedule
agent-config.json  Reproducible Vapi agent definition (not click-through)
deploy.sh          One-command deploy for a fresh VPS
log-collector/     (external repo, linked below) — distributed tracing across
                    frontend/backend/AIS/CV spans, already built
server-monitor/    (external repo, linked below) — SSL + disk alerting, already built
```

---

## What I deployed

- **Voice agent (Part 1):** Vapi assistant ("Sarah"), config in `agent-config.json`,
  phone-number provisioned through Vapi, tool/function calls wired to my backend.
- **Backend:** FastAPI service that receives every Vapi webhook event
  (call started, tool calls, end-of-call report), persists it to Postgres,
  and exposes Prometheus metrics + structured JSON logs.
- **Single VPS, docker-compose** — Postgres, backend, Caddy (auto-TLS reverse
  proxy), Prometheus + Alertmanager, Grafana, and my existing `server-monitor`
  service, all networked together and started with `./deploy.sh`.
- **Backups** — nightly `pg_dump` via cron, rotated at 14 days, with a
  separate restore-test script that actually restores into a throwaway DB
  and checks row counts (not just "the file exists").
- **Telemetry/observability** — I already had a gRPC log collector with
  OpenTelemetry distributed tracing (Jaeger) and Slack alerting, plus
  `server-monitor` for SSL/disk. This build adds the missing piece: call-level
  metrics and structured logs from the actual voice-agent traffic, visualized
  in Grafana, alerting through Prometheus/Alertmanager into the same Discord
  channel `server-monitor` already posts to.

---

## Architecture

```
Patient phone call
      |
      v
   Vapi (telephony + LLM + STT/TTS)
      |  webhooks (call-started, tool-calls, end-of-call-report)
      v
   Caddy (TLS termination, Let's Encrypt auto-renew)
      |
      v
   FastAPI backend  ---writes--->  Postgres (calls, call_events, tool_calls)
      |                                |
      | exposes /metrics               | nightly pg_dump -> local + (optional) S3
      v                                v
   Prometheus  --alerts-->  Alertmanager --> Discord #alerts
      |
      v
   Grafana (dashboards, served at /grafana/)

Separately: server-monitor container watches host disk + the domain's TLS
cert expiry, alerting the same Discord channel.
```

**Why this shape, not Kubernetes:** the brief explicitly rewards judgment
over complexity. At "hundreds of calls/week per practice," a single
well-monitored VPS with docker-compose is operationally simpler to run,
cheaper, and faster to debug than a K8s cluster — and a K8s cluster with no
monitoring (which the brief calls out as a real submission they've seen)
scores worse than a boring VPS with excellent observability. If/when this
scales to dozens of practices and multi-region redundancy actually matters,
migrating the same containers into K8s or ECS is a well-trodden path; it's
not a rewrite.

---

## Cloud deployment status

**Blocked on cloud credentials.** Per the challenge FAQ ("What if I run into
issues with the provided credentials? Contact us immediately... time spent
blocked will not count against you, but we expect you to communicate
proactively"): I emailed the provided contact channel twice requesting
AWS/GCP credentials and had not received them as of submission. `terraform/`
below is written, syntax-checked, and ready to `terraform apply` the moment
credentials arrive — nothing about the deployment is blocked except the
actual cloud account to provision into.

Everything else in this submission (backend, docker-compose stack, backups,
monitoring/alerting, Vapi integration) is fully built and verified running
**locally** via Docker Compose, with the voice agent live and callable
through a Twilio number imported into Vapi, tunneled to my local machine via
ngrok for this submission window.

### Terraform (`terraform/`)

Provisions the cloud equivalent of the local docker-compose stack: a single
EC2 instance (Ubuntu 24.04, encrypted root volume), a security group scoped
to SSH from one IP + HTTP/HTTPS for Caddy's Let's Encrypt flow, and a
cloud-init script that installs Docker, clones this repo, writes `.env` from
Terraform variables (never committed — passed via `terraform.tfvars`, which
is gitignored), and runs the same `docker compose up -d --build` used
locally.

**To apply once credentials exist:**
```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in real values — never commit this file
terraform init
terraform plan
terraform apply
```
Outputs the instance's public IP and the exact next steps (point DNS,
verify cloud-init, swap Vapi's `serverUrl` from the ngrok tunnel to the real
domain).

**What changes vs. the local run:** only `.env` values — `DOMAIN` becomes the
real provided domain instead of the ngrok hostname, and
`scripts/setup-vapi-agent.sh` gets re-run so Vapi's webhook points at the
real server instead of the temporary tunnel. No application code changes are
needed between local and cloud — that's the point of developing against
docker-compose first.

---

## Data flow / traceability

Every call is identified by Vapi's `call_id`. The backend stores:
- `calls` — one row per call, status, timestamps, duration, transcript
- `call_events` — every raw webhook payload received, in order
- `tool_calls` — every function/tool invocation and its arguments

**"What happened on the call at 2:47pm?"** → `GET /calls?limit=...` to find
the `call_id`, then `GET /calls/{call_id}` returns the full event timeline,
transcript, and tool calls in one response. Same question is answerable
visually in Grafana (call volume / error panels) or in Jaeger if the call
touched services instrumented by the log-collector.

Webhook idempotency: Vapi (like most webhook senders) retries on timeout.
Every delivery is deduped via a `webhook_deliveries` table keyed on
Vapi's message/call id before any side effects happen — a retried webhook
never double-counts a call or double-writes a tool call.

---

## Secrets management

- All secrets (Postgres password, Grafana admin password, Vapi webhook
  signing secret, Discord webhook URL) live in `.env`, which is gitignored.
  `.env.example` documents every required variable with no real values.
- The backend verifies Vapi's HMAC-SHA256 webhook signature
  (`X-Vapi-Signature` header) against `VAPI_WEBHOOK_SECRET` before trusting
  any payload — webhooks aren't just "whoever posts to the URL."
- Nothing is hardcoded in source or in `docker-compose.yml`; everything
  flows through `${VAR}` substitution from `.env`.
- **Not implemented, noted as a risk:** a real secrets manager (AWS Secrets
  Manager / Vault). For a single VPS this is a reasonable trade-off — `.env`
  with restrictive file permissions (`chmod 600`) and no shell history
  leakage is the pragmatic baseline. If this handles more than one practice's
  worth of PHI-adjacent infra, I'd move to Secrets Manager with IAM-scoped
  read access before going further.

---

## Security posture / HIPAA awareness

Not fully HIPAA-compliant in 3 hours — that requires a signed BAA with every
vendor in the chain (Vapi, OpenAI/Anthropic, hosting provider) and a real
compliance program. What I did implement, and what I'd flag to an auditor:

**Implemented:**
- TLS everywhere in transit (Caddy auto-provisions and renews Let's Encrypt certs)
- Webhook signature verification (reject unsigned/forged webhook calls)
- Postgres not exposed to the internet — only reachable from the backend
  container over the internal docker network
- `/metrics` and the DB are not internet-facing; only `/webhooks/*`,
  `/calls*`, `/healthz`, and `/grafana/*` are routed through Caddy
- Backend container runs as non-root user
- Structured logs avoid dumping full transcripts into log lines that
  might end up in less-controlled log aggregators (transcripts are stored
  in Postgres, not in stdout logs)

**Not implemented — explicit risks:**
- **Encryption at rest** for the Postgres volume — should use an
  encrypted EBS/persistent-disk volume in a real cloud deploy.
- **BAAs** with Vapi, the LLM provider, and hosting provider — required
  before this touches real PHI.
- **Audit logging** of who accessed patient data and when (distinct from
  application logs) — needed for HIPAA §164.312(b).
- **Network isolation / VPC** — this VPS is a single flat network; a
  production deploy should put Postgres in a private subnet with no public IP.
- **Access control** on Grafana/Prometheus beyond a single admin password —
  no SSO/RBAC configured.
- Transcripts and patient names currently sit in Postgres unencrypted at
  the column level. Field-level encryption for PII would be a next step.

---

## Reliability & incident response

**How would I know if the agent stopped answering calls at 3am?**
- `BackendDown` and `DatabaseUnreachable` Prometheus alerts fire within 1
  minute of the backend or DB becoming unreachable, routed to Discord via
  Alertmanager, `severity: critical` re-notifies every 30 minutes until
  resolved.
- `NoCallsReceivedDuringBusinessHours` catches the "backend is up but Vapi
  integration silently broke" case that a simple uptime check would miss.
- `server-monitor` independently watches the TLS cert (an expired cert is a
  classic silent 3am outage) and host disk usage.
- All of this is a starting point, not a complete on-call story — see
  "Next steps" for what a real on-call rotation would need (PagerDuty
  integration, escalation policies, runbook links in alerts).

**Failure modes and what happens:**
| Failure | Behavior today |
|---|---|
| Postgres down | Backend still accepts webhooks... no, actually returns 500 (webhook write fails), Vapi retries per its own backoff, `DatabaseUnreachable` alert fires. Calls likely fail from the caller's perspective if tool calls depend on DB reads. |
| Backend container crashes | `restart: unless-stopped` restarts it; `BackendDown` alert fires if it doesn't come back within a minute. |
| Vapi webhook signature invalid | Rejected with 401, logged as an error, counted in `voice_webhook_errors_total{reason="bad_signature"}` — visible on the error-rate alert. |
| Duplicate webhook (retry) | Deduped via `webhook_deliveries`, no double-processing. |
| Disk fills up | `server-monitor` alerts at 80% threshold before it becomes an outage. |
| TLS cert about to expire | Caddy auto-renews; `server-monitor` is a second independent check in case Caddy's renewal silently fails. |

**Diagnosing incorrect information given to a patient:** pull the `call_id`
from the complaint, hit `GET /calls/{call_id}` for the full transcript and
tool-call arguments/results, cross-reference with Jaeger traces if the call
touched instrumented backend services. Rollback path: agent behavior lives
in `agent-config.json` (prompt + config) under version control — revert the
commit and re-push via the Vapi API/dashboard to roll back a bad prompt change.

---

## Backups

- `backup/backup.sh` — nightly `pg_dump` (custom format), verifies the dump
  isn't suspiciously small before trusting it, uploads to S3 if configured,
  prunes local copies past 14 days, and pings Discord on any failure so a
  broken backup job is never silently broken for weeks.
- `backup/restore-test.sh` — actually restores a dump into a throwaway
  database and checks row counts. Scheduled weekly via cron
  (`backup/crontab.example`) so restorability is continuously verified, not
  assumed.
- **Known gap:** if `BACKUP_S3_BUCKET` isn't configured, backups are
  local-only on the same VPS as the primary — not a real disaster-recovery
  posture (a dead VPS takes the backups with it). This is flagged explicitly
  rather than glossed over; setting the S3 env vars in `.env` closes the gap
  with no code changes.

---

## Cost

Rough estimate at current scale (few practices, hundreds of calls/week):
- VPS (4 vCPU / 8GB, enough for Postgres + backend + Prometheus/Grafana): ~$40-48/mo
- S3 backup storage (a few GB of dumps): ~$1/mo
- Vapi usage: pay-per-minute, scales with call volume, not covered here
- Domain: already provided

**Total infra (excluding Vapi/LLM usage): roughly $50/month.** This
deliberately does not justify a managed Kubernetes control plane
(~$70+/mo just for the control plane before any nodes) or multi-region
redundancy at this call volume — that's the over-engineering the brief
explicitly warns against.

---

## CI/CD

`.github/workflows/ci.yml` — on every PR/push: compiles the backend,
validates `docker-compose.yml` and all JSON/YAML configs, then brings up
the local stack in the runner and pushes a simulated call through the full
webhook → Postgres → API pipeline (`backend/simulate-call.sh`) as a smoke test.

`.github/workflows/build-push.yml` — on merge to `main` (when `backend/`
changes): builds the backend image and pushes it to GHCR
(`ghcr.io/<org>/<repo>/voice-backend:latest` and `:<sha>`). The deploy job
is stubbed out (`if: false`) pending SSH access to a real host — flip it on
and set `DEPLOY_HOST`/`DEPLOY_USER`/`DEPLOY_SSH_KEY` repo secrets once the
VPS exists, and point `docker-compose.yml`'s backend `build:` at
`image: ghcr.io/<org>/<repo>/voice-backend:latest` instead for the prod deploy.

This closes the "code can be deployed without SSH-ing in and running
commands" gap for the backend image build — remaining manual step is
`docker compose pull && up -d` on the host, which is what the stubbed
deploy job automates once enabled.

---

## What I'd do with more time

1. **Encrypt Postgres at rest** and move it to a managed DB (RDS/Cloud SQL)
   for automated point-in-time recovery instead of nightly-dump-only.
2. **Off-site backups by default** (S3 with versioning + lifecycle policy),
   not opt-in via env var.
3. **Real on-call**: route critical alerts through PagerDuty/Opsgenie with
   escalation policies, not just a Discord channel someone has to be
   watching.
4. **Enable the CI/CD deploy job** — the build/push half is live
   (`.github/workflows/build-push.yml`); the SSH-deploy half is stubbed
   pending a real host to deploy to. Flip it on once the VPS exists.
5. **BAAs and field-level encryption** for patient name/DOB before this
   touches real PHI.
6. **Load/chaos testing** — I have never verified behavior under concurrent
   call spikes or Postgres connection exhaustion; `asyncpg` pool is capped
   at 10 connections, untested against a "500 calls a day" burst pattern.
7. **Private networking** — Postgres and internal services behind a VPC
   with no public IP, bastion-only SSH access.
8. **Correlate Vapi `call_id` with the log-collector's trace IDs** so a
   single call's Jaeger trace and Postgres record are one click apart,
   rather than two separate lookups.

---

## Operating the system (runbook)

**Deploy / redeploy:**
```bash
cp .env.example .env   # fill in real secrets
./deploy.sh
```

**Check health:**
```bash
curl https://$DOMAIN/healthz
docker compose ps
docker compose logs -f backend
```

**View a specific call:**
```bash
curl https://$DOMAIN/calls/<call_id> | jq
```

**Manual backup / restore test:**
```bash
./backup/backup.sh
./backup/restore-test.sh backup/backups/voiceagent_<timestamp>.dump
```

**Dashboards:** `https://$DOMAIN/grafana/` (Voice Agent Operations dashboard,
auto-provisioned). Alerts: Discord `#alerts` channel (shared with
`server-monitor`).

---

## Related repos (already built, referenced by this stack)

- **gRPC Log Collector** — distributed tracing (OpenTelemetry + Jaeger)
  across frontend/backend/AIS/CV spans, worker-pool log ingestion, Slack
  alerting on errors/panics.
- **server-monitor** — Go service checking TLS cert expiry and host disk
  usage, alerting to Discord with per-alert cooldown, `~10MB` scratch image.

Both are wired into this stack's Discord alert channel and (for
server-monitor) the docker-compose network; see `docker-compose.yml`.
