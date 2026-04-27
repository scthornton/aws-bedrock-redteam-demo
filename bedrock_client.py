"""
Minimal AWS Bedrock Converse client using bearer-token (Bedrock API key) auth.

Why no boto3: Bedrock added native bearer-token auth so customers can call the
Converse API without provisioning an IAM service account. That's the OTI-friendly
path this whole demo pivots on - if we required boto3 + sigv4, the customer's
IT/OTI team has to issue an IAM role, which is exactly the friction we're routing
around.

Token format: starts with "ABSK", ~132 chars. Sent as
    Authorization: Bearer <AWS_BEARER_TOKEN_BEDROCK>
to bedrock-runtime.<region>.amazonaws.com.
"""

from __future__ import annotations

import json
import logging
import os
from typing import Any

import requests

log = logging.getLogger(__name__)


class BedrockError(Exception):
    """Raised when Bedrock returns a non-2xx or unparseable response."""

    def __init__(self, message: str, status_code: int | None = None, body: str | None = None):
        super().__init__(message)
        self.status_code = status_code
        self.body = body


def _endpoint(model_id: str, region: str) -> str:
    return f"https://bedrock-runtime.{region}.amazonaws.com/model/{model_id}/converse"


def converse(
    user_message: str,
    system_prompt: str,
    *,
    history: list[dict] | None = None,
    model_id: str | None = None,
    region: str | None = None,
    bearer_token: str | None = None,
    max_tokens: int = 1024,
    temperature: float = 0.7,
    timeout: float = 60.0,
) -> dict[str, Any]:
    """
    Call Bedrock Converse and return the parsed assistant text + token usage.

    history is an optional list of prior turns in OpenAI shape:
        [{"role": "user"|"assistant", "content": "..."}]
    System messages in history are dropped (Bedrock doesn't accept them in
    `messages`; they go into the `system` block, which we already control).

    Returns:
        {
            "text": "<assistant reply>",
            "stop_reason": "end_turn"|"max_tokens"|...,
            "input_tokens": int,
            "output_tokens": int,
            "model_id": "<resolved model>",
        }
    """
    bearer_token = bearer_token or os.environ.get("AWS_BEARER_TOKEN_BEDROCK")
    model_id = model_id or os.environ.get(
        "BEDROCK_MODEL_ID", "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
    )
    region = region or os.environ.get("AWS_REGION", "us-east-1")

    if not bearer_token:
        raise BedrockError("AWS_BEARER_TOKEN_BEDROCK is not set")

    messages = []
    if history:
        for turn in history:
            role = turn.get("role")
            content = turn.get("content", "")
            if role not in ("user", "assistant"):
                continue
            if isinstance(content, list):
                content = " ".join(
                    part.get("text", "") for part in content if isinstance(part, dict)
                )
            text = str(content).strip()
            if not text:
                continue
            messages.append({"role": role, "content": [{"text": text}]})

    messages.append({"role": "user", "content": [{"text": user_message}]})

    payload = {
        "messages": messages,
        "system": [{"text": system_prompt}],
        "inferenceConfig": {"maxTokens": max_tokens, "temperature": temperature},
    }

    url = _endpoint(model_id, region)
    headers = {
        "Authorization": f"Bearer {bearer_token}",
        "Content-Type": "application/json",
    }

    log.debug("Bedrock POST %s (model=%s)", url, model_id)
    resp = requests.post(url, headers=headers, json=payload, timeout=timeout)

    if resp.status_code != 200:
        raise BedrockError(
            f"Bedrock returned HTTP {resp.status_code}",
            status_code=resp.status_code,
            body=resp.text[:2000],
        )

    try:
        body = resp.json()
        content = body["output"]["message"]["content"]
        text = "".join(part.get("text", "") for part in content if isinstance(part, dict))
        usage = body.get("usage", {})
        return {
            "text": text,
            "stop_reason": body.get("stopReason", "end_turn"),
            "input_tokens": usage.get("inputTokens", 0),
            "output_tokens": usage.get("outputTokens", 0),
            "model_id": model_id,
        }
    except (KeyError, ValueError, TypeError) as exc:
        raise BedrockError(
            f"Failed to parse Bedrock response: {exc}",
            status_code=resp.status_code,
            body=resp.text[:2000],
        ) from exc


def health_check(*, bearer_token: str | None = None, model_id: str | None = None,
                 region: str | None = None) -> bool:
    """One-shot 'OK' probe used by /healthz. Returns True if Bedrock answers 200."""
    try:
        result = converse(
            "Reply with exactly: OK",
            "You answer with exactly the word the user requests.",
            bearer_token=bearer_token,
            model_id=model_id,
            region=region,
            max_tokens=10,
            timeout=10.0,
        )
        return bool(result.get("text"))
    except (BedrockError, requests.RequestException):
        return False
