"""
OpenAI-compatible Flask shim for AWS Bedrock - intentionally vulnerable.

Why OpenAI-shaped: Prisma AIRS Red Teaming has a native OpenAI connector. Customer
points it at this app, sets a bearer key, picks any model name, and AIRS fires
attacks at /v1/chat/completions with no custom REST connector configuration.
That's the whole reason this shape exists - lowest-friction integration.

This module is the request entry point only. It owns:
  - Bearer auth check (against DEMO_API_KEY)
  - OpenAI <-> Bedrock request/response shape translation
  - Calling out to bedrock_client.converse with the vulnerable system prompt
  - Optional pre/post AIRS Runtime overlay (lands in the next PR)

Vulnerabilities live in vulnerabilities.py. The translation layer here does NOT
add any of its own; this file is meant to stay readable and audit-friendly.
"""

from __future__ import annotations

import json
import logging
import os
import time
import uuid

from flask import Flask, Response, jsonify, request

import airs_runtime
from bedrock_client import BedrockError, converse, health_check
from vulnerabilities import build_system_prompt, vulnerability_categories

try:
    from dotenv import load_dotenv

    load_dotenv()
except ImportError:
    pass

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s | %(message)s",
)
log = logging.getLogger("app")

app = Flask(__name__)


def _config(name: str, default: str | None = None, *, required: bool = False) -> str:
    val = os.environ.get(name, default)
    if required and not val:
        raise RuntimeError(f"Required env var {name} is not set")
    return val or ""


DEMO_API_KEY = _config("DEMO_API_KEY", required=True)
BEDROCK_MODEL_ID = _config("BEDROCK_MODEL_ID", "us.anthropic.claude-sonnet-4-5-20250929-v1:0")
APP_NAME = _config("APP_NAME", "aws-bedrock-redteam-demo")
BLOCK_STATUS_CODE = int(_config("BLOCK_STATUS_CODE", "200"))


def _check_auth() -> tuple[bool, Response | None]:
    """Validate Authorization: Bearer <DEMO_API_KEY>. Returns (ok, error_response)."""
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return False, _error_response(
            "missing_bearer", "Authorization: Bearer <key> header required", status=401
        )
    token = auth.removeprefix("Bearer ").strip()
    if token != DEMO_API_KEY:
        return False, _error_response("invalid_api_key", "Invalid API key", status=401)
    return True, None


def _error_response(code: str, message: str, status: int = 400) -> Response:
    payload = {"error": {"type": "invalid_request_error", "code": code, "message": message}}
    return Response(json.dumps(payload), status=status, mimetype="application/json")


def _to_openai_response(text: str, *, model: str, prompt_tokens: int, completion_tokens: int,
                       finish_reason: str = "stop") -> dict:
    """
    Wrap a Bedrock reply in OpenAI ChatCompletion shape.

    Also exposes the assistant text under a top-level `output` field. The
    AIRS Red Teaming REST connector's response template uses a flat
    `{"output": "{RESPONSE}"}` shape - it does not appear to traverse
    nested objects to extract the AI text. Adding `output` at the top
    level keeps the canonical OpenAI shape intact (clients ignore extra
    fields) while letting the AIRS template extract cleanly.
    """
    return {
        "id": f"chatcmpl-{uuid.uuid4().hex}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model,
        "output": text,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": text},
                "finish_reason": finish_reason,
            }
        ],
        "usage": {
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "total_tokens": prompt_tokens + completion_tokens,
        },
    }


def _bedrock_finish_reason(stop_reason: str) -> str:
    """Map Bedrock stopReason values to OpenAI finish_reason."""
    if stop_reason == "max_tokens":
        return "length"
    if stop_reason in ("end_turn", "stop_sequence"):
        return "stop"
    return "stop"


# ---------- Endpoints ----------


@app.get("/healthz")
def healthz():
    bedrock_ok = health_check(model_id=BEDROCK_MODEL_ID)
    status = "ok" if bedrock_ok else "degraded"
    return jsonify(
        {
            "status": status,
            "app": APP_NAME,
            "bedrock_model": BEDROCK_MODEL_ID,
            "bedrock_reachable": bedrock_ok,
            "runtime_security_enabled": airs_runtime.is_enabled(),
            "airs_profile": os.environ.get("AIRS_PROFILE", "chatbot")
            if airs_runtime.is_enabled()
            else None,
            "vulnerabilities": vulnerability_categories(),
        }
    )


@app.get("/v1/models")
def list_models():
    """Mimic OpenAI's /v1/models. We expose exactly one: the configured Bedrock model."""
    ok, err = _check_auth()
    if not ok:
        return err
    return jsonify(
        {
            "object": "list",
            "data": [
                {
                    "id": BEDROCK_MODEL_ID,
                    "object": "model",
                    "created": int(time.time()),
                    "owned_by": "aws-bedrock",
                }
            ],
        }
    )


@app.post("/v1/chat/completions")
def chat_completions():
    ok, err = _check_auth()
    if not ok:
        return err

    try:
        body = request.get_json(force=True, silent=False) or {}
    except Exception:
        return _error_response("invalid_json", "Request body must be valid JSON", status=400)

    messages = body.get("messages") or []
    if not isinstance(messages, list) or not messages:
        return _error_response("missing_messages", "`messages` must be a non-empty array")

    user_messages = [m for m in messages if m.get("role") == "user"]
    if not user_messages:
        return _error_response("missing_user_message", "At least one user message is required")

    last_user = user_messages[-1]
    user_content = last_user.get("content", "")
    if isinstance(user_content, list):
        user_content = " ".join(
            part.get("text", "") for part in user_content if isinstance(part, dict)
        )
    user_text = str(user_content).strip()
    if not user_text:
        return _error_response("empty_user_message", "User message content is empty")

    history = []
    for m in messages[:-1]:
        if m.get("role") in ("user", "assistant"):
            history.append({"role": m["role"], "content": m.get("content", "")})

    requested_model = body.get("model") or BEDROCK_MODEL_ID
    max_tokens = int(body.get("max_tokens", 1024) or 1024)
    temperature = float(body.get("temperature", 0.7) or 0.7)
    app_user = body.get("user") or "anonymous"
    tr_id = uuid.uuid4().hex

    log.info("chat req tr=%s model=%s user_chars=%d history_turns=%d airs=%s",
             tr_id, requested_model, len(user_text), len(history), airs_runtime.is_enabled())

    # ---------- Pre-call AIRS scan (prompt only) ----------
    if airs_runtime.is_enabled():
        pre = airs_runtime.scan(
            prompt=user_text,
            ai_model=BEDROCK_MODEL_ID,
            app_user=app_user,
            tr_id=tr_id,
        )
        if pre.get("action") == "block":
            threats = airs_runtime.detected_threats(pre, side="prompt")
            log.info(
                "airs PRE block tr=%s threats=%s report=%s",
                tr_id, threats, pre.get("report_id"),
            )
            return Response(
                json.dumps(
                    _to_openai_response(
                        text=airs_runtime.block_message(pre, side="prompt"),
                        model=requested_model,
                        prompt_tokens=0,
                        completion_tokens=0,
                        finish_reason="content_filter",
                    )
                ),
                status=BLOCK_STATUS_CODE,
                mimetype="application/json",
            )
        log.info("airs PRE allow tr=%s latency=%sms", tr_id, pre.get("_latency_ms"))

    # ---------- Bedrock call ----------
    try:
        result = converse(
            user_message=user_text,
            system_prompt=build_system_prompt(),
            history=history,
            model_id=BEDROCK_MODEL_ID,
            max_tokens=max_tokens,
            temperature=temperature,
        )
    except BedrockError as exc:
        log.warning("bedrock error: %s status=%s", exc, exc.status_code)
        return _error_response(
            "bedrock_error",
            f"Bedrock returned HTTP {exc.status_code or 'unknown'}: {exc}",
            status=502,
        )

    response_text = result["text"]
    finish_reason = _bedrock_finish_reason(result["stop_reason"])

    # ---------- Post-call AIRS scan (prompt + response) ----------
    if airs_runtime.is_enabled():
        post = airs_runtime.scan(
            prompt=user_text,
            response=response_text,
            ai_model=BEDROCK_MODEL_ID,
            app_user=app_user,
            tr_id=tr_id,
        )
        if post.get("action") == "block":
            threats = airs_runtime.detected_threats(post, side="response")
            log.info(
                "airs POST block tr=%s threats=%s report=%s",
                tr_id, threats, post.get("report_id"),
            )
            response_text = airs_runtime.block_message(post, side="response")
            finish_reason = "content_filter"
            return Response(
                json.dumps(
                    _to_openai_response(
                        text=response_text,
                        model=requested_model,
                        prompt_tokens=result["input_tokens"],
                        completion_tokens=0,
                        finish_reason=finish_reason,
                    )
                ),
                status=BLOCK_STATUS_CODE,
                mimetype="application/json",
            )
        log.info("airs POST allow tr=%s latency=%sms", tr_id, post.get("_latency_ms"))

    return jsonify(
        _to_openai_response(
            text=response_text,
            model=requested_model,
            prompt_tokens=result["input_tokens"],
            completion_tokens=result["output_tokens"],
            finish_reason=finish_reason,
        )
    )


@app.post("/api/chat")
def airs_flat_chat():
    """
    Dedicated AIRS Red Teaming endpoint that returns the flat response shape
    AIRS's REST connector template `{"output":"{RESPONSE}"}` reliably extracts.

    Why this exists: the OpenAI `/v1/chat/completions` route returns nested
    JSON (`choices[0].message.content`) plus extra fields like `id`, `model`,
    `usage`. The AIRS REST connector's template-based extraction has trouble
    with deeply-nested response shapes, even when the template mirrors them.
    This route bypasses all that ambiguity by returning ONLY `{"output": ...}`,
    matching the pattern of every reliably-working AIRS public-vulnerable demo.

    Accepts the same body shapes AIRS might be configured to send:
      - {"messages":[{"role":"user","content":"..."}]}  (OpenAI-shape, our default body template)
      - {"input": "..."}                                (DVLA-shape, plain prompt)

    Returns exactly:
      {"output": "<assistant text or block message>"}

    Auth (DEMO_API_KEY) and the AIRS Runtime overlay are wired in the same
    way as /v1/chat/completions; the only difference is the I/O shape.
    """
    ok, err = _check_auth()
    if not ok:
        return err

    try:
        body = request.get_json(force=True, silent=False) or {}
    except Exception:
        return _error_response("invalid_json", "Request body must be valid JSON", status=400)

    user_text = ""
    if isinstance(body.get("input"), str):
        user_text = body["input"].strip()
    elif isinstance(body.get("messages"), list):
        user_msgs = [m for m in body["messages"] if m.get("role") == "user"]
        if user_msgs:
            content = user_msgs[-1].get("content", "")
            if isinstance(content, list):
                content = " ".join(p.get("text", "") for p in content if isinstance(p, dict))
            user_text = str(content).strip()

    if not user_text:
        return _error_response(
            "missing_input",
            "Body must include either 'input' (string) or 'messages' (OpenAI-shape array)",
        )

    history = []
    if isinstance(body.get("messages"), list):
        for m in body["messages"][:-1]:
            if m.get("role") in ("user", "assistant"):
                history.append({"role": m["role"], "content": m.get("content", "")})

    app_user = body.get("user") or "anonymous"
    tr_id = uuid.uuid4().hex

    log.info("api/chat req tr=%s user_chars=%d history_turns=%d airs=%s",
             tr_id, len(user_text), len(history), airs_runtime.is_enabled())

    if airs_runtime.is_enabled():
        pre = airs_runtime.scan(prompt=user_text, ai_model=BEDROCK_MODEL_ID,
                                app_user=app_user, tr_id=tr_id)
        if pre.get("action") == "block":
            log.info("airs PRE block tr=%s threats=%s",
                     tr_id, airs_runtime.detected_threats(pre, side="prompt"))
            return Response(
                json.dumps({"output": airs_runtime.block_message(pre, side="prompt")}),
                status=BLOCK_STATUS_CODE, mimetype="application/json",
            )

    try:
        result = converse(
            user_message=user_text,
            system_prompt=build_system_prompt(),
            history=history,
            model_id=BEDROCK_MODEL_ID,
            max_tokens=int(body.get("max_tokens", 1024) or 1024),
            temperature=float(body.get("temperature", 0.7) or 0.7),
        )
    except BedrockError as exc:
        log.warning("bedrock error: %s status=%s", exc, exc.status_code)
        return _error_response(
            "bedrock_error",
            f"Bedrock returned HTTP {exc.status_code or 'unknown'}: {exc}",
            status=502,
        )

    response_text = result["text"]

    if airs_runtime.is_enabled():
        post = airs_runtime.scan(prompt=user_text, response=response_text,
                                 ai_model=BEDROCK_MODEL_ID, app_user=app_user, tr_id=tr_id)
        if post.get("action") == "block":
            log.info("airs POST block tr=%s threats=%s",
                     tr_id, airs_runtime.detected_threats(post, side="response"))
            return Response(
                json.dumps({"output": airs_runtime.block_message(post, side="response")}),
                status=BLOCK_STATUS_CODE, mimetype="application/json",
            )

    return Response(json.dumps({"output": response_text}), status=200,
                    mimetype="application/json")


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    app.run(host="0.0.0.0", port=port, debug=False)
