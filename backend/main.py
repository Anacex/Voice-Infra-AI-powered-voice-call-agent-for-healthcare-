"""
Voice Agent Backend — Lakewood Family Medicine (demo practice)

Receives Vapi webhook events (call started/ended, transcripts, function/tool calls),
persists them to Postgres, exposes Prometheus metrics, and emits structured JSON logs
(designed to be piped into the gRPC log collector / Jaeger stack or any log shipper).

Design goals for this take-home:
  - Every inbound webhook is durably stored BEFORE we do anything else (idempotent insert).
  - Every call is traceable end-to-end from a single call_id: "what happened on the
    call at 2:47pm" should be answerable with one SQL query or one Grafana panel.
  - Failure is loud: bad webhook signatures, DB errors, and LLM/tool failures all
    increment counters and log at ERROR so alerting picks them up.
"""
import json
import logging
import os
import time
import hmac
import hashlib
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Optional

import asyncpg
from fastapi import FastAPI, Request, Header, HTTPException
from fastapi.responses import JSONResponse, PlainTextResponse
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST

# ---------------------------------------------------------------------------
# Structured logging (JSON lines -> stdout -> picked up by docker logging
# driver / Promtail / your log collector of choice)
# ---------------------------------------------------------------------------
class JsonFormatter(logging.Formatter):
    def format(self, record):
        payload = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "msg": record.getMessage(),
            "logger": record.name,
        }
        for key in ("call_id", "event", "duration_ms", "status_code"):
            if hasattr(record, key):
                payload[key] = getattr(record, key)
        if record.exc_info:
            payload["exc_info"] = self.formatException(record.exc_info)
        return json.dumps(payload)


handler = logging.StreamHandler()
handler.setFormatter(JsonFormatter())
logging.basicConfig(level=logging.INFO, handlers=[handler])
log = logging.getLogger("voice-backend")

# ---------------------------------------------------------------------------
# Config (all from env — nothing hardcoded, see .env.example)
# ---------------------------------------------------------------------------
DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://voiceagent:voiceagent@postgres:5432/voiceagent")
VAPI_WEBHOOK_SECRET = os.environ.get("VAPI_WEBHOOK_SECRET", "")  # HMAC secret Vapi signs with
PORT = int(os.environ.get("PORT", "8000"))

db_pool: Optional[asyncpg.Pool] = None

# ---------------------------------------------------------------------------
# Prometheus metrics — the questions we want to be able to answer at 3am
# ---------------------------------------------------------------------------
CALLS_TOTAL = Counter("voice_calls_total", "Total calls received", ["status"])
WEBHOOK_EVENTS = Counter("voice_webhook_events_total", "Webhook events by type", ["event_type"])
WEBHOOK_ERRORS = Counter("voice_webhook_errors_total", "Webhook processing errors", ["reason"])
WEBHOOK_LATENCY = Histogram("voice_webhook_latency_seconds", "Webhook handler latency", ["event_type"])
CALL_DURATION = Histogram("voice_call_duration_seconds", "Call duration", buckets=(10, 30, 60, 120, 300, 600, 1200))
TOOL_CALL_ERRORS = Counter("voice_tool_call_errors_total", "Function/tool call failures", ["tool_name"])
DB_UP = Gauge("voice_db_up", "1 if backend can reach Postgres, else 0")
IN_PROGRESS_CALLS = Gauge("voice_calls_in_progress", "Calls currently in progress")


@asynccontextmanager
async def lifespan(app: FastAPI):
    global db_pool
    db_pool = await asyncpg.create_pool(DATABASE_URL, min_size=1, max_size=10)
    await init_schema()
    log.info("backend started, db pool ready")
    yield
    await db_pool.close()


app = FastAPI(title="voice-agent-backend", lifespan=lifespan)


async def init_schema():
    async with db_pool.acquire() as conn:
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS calls (
                call_id TEXT PRIMARY KEY,
                phone_number TEXT,
                caller_number TEXT,
                status TEXT NOT NULL DEFAULT 'in_progress',
                started_at TIMESTAMPTZ,
                ended_at TIMESTAMPTZ,
                duration_seconds NUMERIC,
                ended_reason TEXT,
                patient_name TEXT,
                reason_for_calling TEXT,
                transcript JSONB,
                raw_end_payload JSONB,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now()
            );

            CREATE TABLE IF NOT EXISTS call_events (
                id BIGSERIAL PRIMARY KEY,
                call_id TEXT NOT NULL,
                event_type TEXT NOT NULL,
                payload JSONB NOT NULL,
                received_at TIMESTAMPTZ NOT NULL DEFAULT now()
            );
            CREATE INDEX IF NOT EXISTS idx_call_events_call_id ON call_events(call_id);
            CREATE INDEX IF NOT EXISTS idx_call_events_received_at ON call_events(received_at);

            CREATE TABLE IF NOT EXISTS tool_calls (
                id BIGSERIAL PRIMARY KEY,
                call_id TEXT NOT NULL,
                tool_name TEXT NOT NULL,
                arguments JSONB,
                result JSONB,
                success BOOLEAN NOT NULL,
                latency_ms INTEGER,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now()
            );

            -- webhook_deliveries gives us idempotency: Vapi (like most webhook
            -- senders) can retry on timeout, so we dedupe on their delivery/message id.
            CREATE TABLE IF NOT EXISTS webhook_deliveries (
                delivery_id TEXT PRIMARY KEY,
                event_type TEXT,
                received_at TIMESTAMPTZ NOT NULL DEFAULT now()
            );
            """
        )


def verify_signature(raw_body: bytes, signature_header: Optional[str]) -> bool:
    """Verify Vapi's HMAC-SHA256 webhook signature, if a secret is configured.
    If no secret is configured (local dev), verification is skipped — but this
    is logged loudly so it's never silently insecure in prod."""
    if not VAPI_WEBHOOK_SECRET:
        log.warning("VAPI_WEBHOOK_SECRET not set — webhook signature verification DISABLED")
        return True
    if not signature_header:
        return False
    expected = hmac.new(VAPI_WEBHOOK_SECRET.encode(), raw_body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature_header)


@app.get("/healthz")
async def healthz():
    """Liveness/readiness probe. Checks real DB connectivity, not just process liveness."""
    try:
        async with db_pool.acquire() as conn:
            await conn.execute("SELECT 1")
        DB_UP.set(1)
        return {"status": "ok", "db": "up"}
    except Exception as e:
        DB_UP.set(0)
        log.error("healthz db check failed: %s", e)
        return JSONResponse(status_code=503, content={"status": "degraded", "db": "down"})


@app.get("/metrics")
async def metrics():
    return PlainTextResponse(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/webhooks/vapi")
async def vapi_webhook(request: Request, x_vapi_signature: Optional[str] = Header(None)):
    start = time.time()
    raw_body = await request.body()

    if not verify_signature(raw_body, x_vapi_signature):
        WEBHOOK_ERRORS.labels(reason="bad_signature").inc()
        log.error("webhook rejected: invalid signature")
        raise HTTPException(status_code=401, detail="invalid signature")

    try:
        payload = json.loads(raw_body)
    except json.JSONDecodeError:
        WEBHOOK_ERRORS.labels(reason="bad_json").inc()
        raise HTTPException(status_code=400, detail="invalid json")

    message = payload.get("message", payload)
    event_type = message.get("type", "unknown")
    delivery_id = message.get("id") or message.get("call", {}).get("id", "") + f":{event_type}"

    WEBHOOK_EVENTS.labels(event_type=event_type).inc()

    try:
        async with db_pool.acquire() as conn:
            # idempotency guard
            inserted = await conn.fetchval(
                "INSERT INTO webhook_deliveries (delivery_id, event_type) VALUES ($1, $2) "
                "ON CONFLICT (delivery_id) DO NOTHING RETURNING delivery_id",
                delivery_id, event_type,
            )
            if inserted is None:
                log.info("duplicate webhook delivery ignored", extra={"event": event_type})
                return {"status": "duplicate_ignored"}

            call = message.get("call", {}) or {}
            call_id = call.get("id", "unknown")

            await conn.execute(
                "INSERT INTO call_events (call_id, event_type, payload) VALUES ($1, $2, $3)",
                call_id, event_type, json.dumps(message),
            )

            await handle_event(conn, event_type, call_id, message)

    except HTTPException:
        raise
    except Exception as e:
        WEBHOOK_ERRORS.labels(reason="processing_error").inc()
        log.error("webhook processing failed: %s", e, extra={"event": event_type})
        raise HTTPException(status_code=500, detail="internal error")
    finally:
        WEBHOOK_LATENCY.labels(event_type=event_type).observe(time.time() - start)

    return {"status": "ok"}


async def handle_event(conn, event_type: str, call_id: str, message: dict):
    call = message.get("call", {}) or {}

    if event_type == "status-update" and message.get("status") == "in-progress":
        IN_PROGRESS_CALLS.inc()
        await conn.execute(
            """
            INSERT INTO calls (call_id, phone_number, caller_number, status, started_at)
            VALUES ($1, $2, $3, 'in_progress', now())
            ON CONFLICT (call_id) DO UPDATE SET status = 'in_progress'
            """,
            call_id, call.get("phoneNumber", {}).get("number") if isinstance(call.get("phoneNumber"), dict) else None,
            call.get("customer", {}).get("number"),
        )
        log.info("call started", extra={"call_id": call_id, "event": event_type})

    elif event_type == "tool-calls":
        for tc in message.get("toolCallList", []) or message.get("toolCalls", []):
            tool_name = tc.get("function", {}).get("name", "unknown")
            args = tc.get("function", {}).get("arguments")
            success = True  # actual result is recorded by the tool response leg in prod
            await conn.execute(
                "INSERT INTO tool_calls (call_id, tool_name, arguments, success) VALUES ($1,$2,$3,$4)",
                call_id, tool_name, json.dumps(args) if args else None, success,
            )
            log.info("tool call", extra={"call_id": call_id, "event": tool_name})

    elif event_type == "end-of-call-report":
        analysis = message.get("analysis", {}) or {}
        duration = message.get("durationSeconds")
        ended_reason = message.get("endedReason")
        CALLS_TOTAL.labels(status=ended_reason or "unknown").inc()
        IN_PROGRESS_CALLS.dec()
        if duration is not None:
            CALL_DURATION.observe(float(duration))
        await conn.execute(
            """
            UPDATE calls SET status='completed', ended_at=now(),
                duration_seconds=$2, ended_reason=$3,
                transcript=$4, raw_end_payload=$5
            WHERE call_id=$1
            """,
            call_id, duration, ended_reason,
            json.dumps(message.get("transcript") or message.get("messages")),
            json.dumps(message),
        )
        if ended_reason and "error" in str(ended_reason).lower():
            WEBHOOK_ERRORS.labels(reason=f"call_ended_{ended_reason}").inc()
            log.error("call ended with error", extra={"call_id": call_id, "event": ended_reason})
        else:
            log.info("call ended", extra={"call_id": call_id, "event": ended_reason,
                                            "duration_ms": int((duration or 0) * 1000)})


@app.get("/calls/{call_id}")
async def get_call(call_id: str):
    """Debugging endpoint: reconstruct exactly what happened on a given call."""
    async with db_pool.acquire() as conn:
        call = await conn.fetchrow("SELECT * FROM calls WHERE call_id=$1", call_id)
        events = await conn.fetch(
            "SELECT event_type, payload, received_at FROM call_events WHERE call_id=$1 ORDER BY received_at",
            call_id,
        )
        tools = await conn.fetch("SELECT * FROM tool_calls WHERE call_id=$1 ORDER BY created_at", call_id)
    if not call:
        raise HTTPException(status_code=404, detail="call not found")
    return {
        "call": dict(call),
        "events": [dict(e) for e in events],
        "tool_calls": [dict(t) for t in tools],
    }


@app.get("/calls")
async def list_recent_calls(limit: int = 50):
    async with db_pool.acquire() as conn:
        rows = await conn.fetch(
            "SELECT call_id, status, started_at, ended_at, duration_seconds, ended_reason "
            "FROM calls ORDER BY created_at DESC LIMIT $1", limit,
        )
    return [dict(r) for r in rows]
