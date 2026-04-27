"""
Optional Prisma AIRS Runtime Security overlay.

This module is the integration glue for the before/after demo. When
ENABLE_RUNTIME_SECURITY=true, app.py calls scan() twice per chat completion:

  1. Pre-call: scan the user's prompt before we hand it to Bedrock. If AIRS
     returns action=block, we short-circuit and return a block message in
     OpenAI shape with HTTP BLOCK_STATUS_CODE (default 200).
  2. Post-call: scan the model's response. If AIRS returns action=block,
     we replace the response body with a block message.

  Why HTTP 200 on block: AIRS Red Teaming's response parser scores by body
  content. Returning 4xx classifies the request as an API error rather than
  an attack outcome, which collapses the demo's signal. Configurable via
  BLOCK_STATUS_CODE only for production tuning, NOT for this demo flow.

Fail-open: if AIRS itself errors (network, 5xx, JSON parse failure), we
log and return action=allow. Users get a working chatbot even if the
overlay's control plane is down. This is intentional - the demo target
is the LLM app, not AIRS itself.

API reference:
  POST <AIRS_API_URL>
  Headers:
    x-pan-token: <AIRS_API_KEY>
    Content-Type: application/json
  Body:
    {
      "tr_id": "<unique transaction id>",
      "ai_profile": {"profile_name": "<profile>"},
      "metadata": {"app_name": "...", "app_user": "...", "ai_model": "..."},
      "contents": [{"prompt": "...", "response": "<optional>"}]
    }
"""

from __future__ import annotations

import logging
import os
import time
import uuid
from typing import Any

import requests

log = logging.getLogger(__name__)

DEFAULT_URL = "https://service.api.aisecurity.paloaltonetworks.com/v1/scan/sync/request"
DEFAULT_PROFILE = "chatbot"
DEFAULT_TIMEOUT = 10.0


def is_enabled() -> bool:
    """Truthy if ENABLE_RUNTIME_SECURITY is set to a recognized true value."""
    return os.environ.get("ENABLE_RUNTIME_SECURITY", "false").strip().lower() in {
        "1",
        "true",
        "yes",
        "on",
    }


def scan(
    prompt: str,
    response: str | None = None,
    *,
    api_key: str | None = None,
    profile: str | None = None,
    api_url: str | None = None,
    app_name: str | None = None,
    app_user: str | None = None,
    ai_model: str | None = None,
    tr_id: str | None = None,
    timeout: float = DEFAULT_TIMEOUT,
) -> dict[str, Any]:
    """
    Run a synchronous AIRS scan and return the parsed JSON.

    On any error (missing key, network, non-2xx, parse failure), returns:
        {"action": "allow", "_error": "<reason>"}
    so the caller can keep serving traffic. The "_error" field is for our
    own logging only - production code should treat this dict the same way
    it treats a real allow.

    Returns the AIRS response dict. Key fields the caller will look at:
        action          "block" | "allow" | "alert"
        category        "malicious" | "benign"
        prompt_detected dict[str, bool] of detection categories
        response_detected dict[str, bool] (only when response was scanned)
        report_id       AIRS report ID
        scan_id         AIRS scan ID
    """
    api_key = api_key or os.environ.get("AIRS_API_KEY")
    profile = profile or os.environ.get("AIRS_PROFILE", DEFAULT_PROFILE)
    api_url = api_url or os.environ.get("AIRS_API_URL", DEFAULT_URL)
    app_name = app_name or os.environ.get("APP_NAME", "aws-bedrock-redteam-demo")
    app_user = app_user or "anonymous"
    ai_model = ai_model or os.environ.get("BEDROCK_MODEL_ID", "unknown")
    tr_id = tr_id or uuid.uuid4().hex

    if not api_key:
        log.warning("AIRS scan skipped: AIRS_API_KEY is not set; failing open")
        return {"action": "allow", "_error": "AIRS_API_KEY not set"}

    content: dict[str, str] = {"prompt": prompt}
    if response is not None:
        content["response"] = response

    payload = {
        "tr_id": tr_id,
        "ai_profile": {"profile_name": profile},
        "metadata": {"app_name": app_name, "app_user": app_user, "ai_model": ai_model},
        "contents": [content],
    }

    headers = {"x-pan-token": api_key, "Content-Type": "application/json"}

    started = time.perf_counter()
    try:
        resp = requests.post(api_url, headers=headers, json=payload, timeout=timeout)
    except requests.RequestException as exc:
        log.warning("AIRS scan network error (failing open): %s", exc)
        return {"action": "allow", "_error": f"network: {exc}"}

    latency_ms = int((time.perf_counter() - started) * 1000)

    if resp.status_code != 200:
        log.warning(
            "AIRS scan returned HTTP %s (failing open): %s",
            resp.status_code,
            resp.text[:300],
        )
        return {
            "action": "allow",
            "_error": f"http {resp.status_code}",
            "_latency_ms": latency_ms,
        }

    try:
        data = resp.json()
    except ValueError as exc:
        log.warning("AIRS scan returned unparseable JSON (failing open): %s", exc)
        return {"action": "allow", "_error": f"parse: {exc}", "_latency_ms": latency_ms}

    data["_latency_ms"] = latency_ms
    return data


def detected_threats(scan_result: dict[str, Any], side: str = "prompt") -> list[str]:
    """Return the list of detection categories that fired in a scan result."""
    key = "prompt_detected" if side == "prompt" else "response_detected"
    detections = scan_result.get(key) or {}
    return [name for name, hit in detections.items() if hit]


def block_message(scan_result: dict[str, Any], side: str = "prompt") -> str:
    """Format a human-readable block message including the AIRS report id."""
    threats = detected_threats(scan_result, side=side)
    threat_list = ", ".join(threats) if threats else "policy violation"
    report_id = scan_result.get("report_id", "unknown")
    side_label = "prompt" if side == "prompt" else "model response"
    return (
        f"This request was blocked by Prisma AIRS Runtime Security on the "
        f"{side_label} (detected: {threat_list}). AIRS report id: {report_id}."
    )
