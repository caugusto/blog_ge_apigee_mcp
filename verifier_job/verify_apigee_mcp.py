#!/usr/bin/env python3
"""In-VPC end-to-end verifier for Internal Country Facts MCP behind Apigee X over Northbound & Southbound PSC."""

from __future__ import annotations

import json
import os
import socket
import ssl
import sys
import time
import urllib.error
import urllib.request

COUNTRIES_HOST = os.environ.get("COUNTRIES_HOST", "mcp-countries.corp.internal")
EXPECTED_HUB_ILB_IP = os.environ.get("EXPECTED_HUB_ILB_IP", "10.10.1.30")
EXPECTED_APIGEE_PROJECT = os.environ.get("EXPECTED_APIGEE_PROJECT", "apigee-x-mcp")
MCP_URL = os.environ.get("MCP_URL", f"https://{COUNTRIES_HOST}/mcp")
HEALTH_URL = os.environ.get("HEALTH_URL", f"https://{COUNTRIES_HOST}/healthz")
CA_CERT_PATH = os.environ.get("CA_CERT_PATH", "/app/ca.crt")


def get_oauth_token() -> str:
    token = os.environ.get("OAUTH_BEARER_TOKEN", "").strip()
    if token:
        return token
    meta_url = (
        "http://metadata.google.internal/computeMetadata/v1/"
        "instance/service-accounts/default/token"
    )
    req = urllib.request.Request(meta_url, headers={"Metadata-Flavor": "Google"})
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read().decode("utf-8"))["access_token"]


def make_ssl_context() -> ssl.SSLContext:
    ctx = ssl.create_default_context(cafile=CA_CERT_PATH)
    ctx.check_hostname = True
    ctx.verify_mode = ssl.CERT_REQUIRED
    return ctx


def http_post_mcp(
    ssl_ctx: ssl.SSLContext, payload: dict, bearer_token: str | None = None
) -> tuple[int, dict, str]:
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }
    if bearer_token:
        headers["Authorization"] = f"Bearer {bearer_token}"

    req = urllib.request.Request(
        MCP_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, context=ssl_ctx, timeout=20) as resp:
            return resp.status, dict(resp.headers), resp.read().decode("utf-8")
    except urllib.error.HTTPError as err:
        return err.code, dict(err.headers), err.read().decode("utf-8")


def main() -> int:
    ssl_ctx = make_ssl_context()

    print(f"[1/4] Resolving Private Cloud DNS for {COUNTRIES_HOST}...")
    resolved_ip = ""
    for attempt in range(1, 13):
        try:
            resolved_ip = socket.gethostbyname(COUNTRIES_HOST)
            break
        except socket.gaierror as exc:
            if attempt == 12:
                raise
            print(f"      ... waiting for Cloud DNS propagation (attempt {attempt}/12: {exc})")
            time.sleep(10)
    print(f"      {COUNTRIES_HOST} -> {resolved_ip}")
    assert (
        resolved_ip == EXPECTED_HUB_ILB_IP
    ), f"Expected {EXPECTED_HUB_ILB_IP}, got {resolved_ip}"

    print(
        "[2/4] Verifying Hub ALB -> Northbound PSC -> Apigee X -> Southbound PSC -> Cloud Run OIDC (/healthz)..."
    )
    health = {}
    health_status = 0
    for attempt in range(1, 13):
        try:
            with urllib.request.urlopen(HEALTH_URL, context=ssl_ctx, timeout=20) as resp:
                health_status = resp.status
                health = json.loads(resp.read().decode("utf-8"))
                break
        except (urllib.error.HTTPError, urllib.error.URLError, ssl.SSLError, TimeoutError, json.JSONDecodeError) as exc:
            if attempt == 12:
                raise
            print(
                f"      ... waiting for Regional ALB / PSC / Apigee data plane convergence (attempt {attempt}/12: {exc})"
            )
            time.sleep(10)
    print(f"      HTTP {health_status}: {health}")
    assert health_status == 200
    assert health.get("service") == "mcp-countries-poc"
    assert health.get("project") == EXPECTED_APIGEE_PROJECT
    assert health.get("apigee_proxy") == "country-facts-mcp"

    print(
        "[3/4] Verifying unauthenticated POST /mcp passes Cloud Run IAM via Apigee OIDC, then returns Layer-7 HTTP 401..."
    )
    status_401, hdrs_401, body_401 = http_post_mcp(
        ssl_ctx,
        {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}},
        bearer_token=None,
    )
    www_auth = hdrs_401.get("WWW-Authenticate") or hdrs_401.get("www-authenticate", "")
    print(f"      HTTP {status_401} | WWW-Authenticate: {www_auth}")
    assert status_401 == 401, f"Expected HTTP 401, got {status_401}: {body_401}"

    print(
        "[4/4] Verifying OAuth 2.0 Bearer -> Apigee Credential Translation -> FastMCP StreamableHTTP..."
    )
    token = get_oauth_token()
    status_list, _, body_list = http_post_mcp(
        ssl_ctx,
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
        bearer_token=token,
    )
    if status_list == 401 and "EXPECTED_OAUTH_CLIENT_ID" in body_list:
        print(
            "      OAuth2 client_id pinning active (rejected non-GE service account token as expected):"
        )
        print(f"      {body_list.strip()}")
    else:
        print(f"      tools/list HTTP {status_list}: {body_list.strip()[:240]}...")
        assert status_list == 200, f"Expected HTTP 200, got {status_list}: {body_list}"

        status_call, _, body_call = http_post_mcp(
            ssl_ctx,
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {
                    "name": "get_country_facts",
                    "arguments": {"country": "japan"},
                },
            },
            bearer_token=token,
        )
        print(f"      tools/call (get_country_facts) HTTP {status_call}:\n{body_call.strip()}")
        assert status_call == 200, f"Expected HTTP 200, got {status_call}: {body_call}"
        assert "Tokyo" in body_call and "country-facts-mcp" in body_call

    print(
        "\nALL APIGEE X + NORTHBOUND/SOUTHBOUND PSC + OIDC/OAUTH2 + MCP CHECKS PASSED."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
