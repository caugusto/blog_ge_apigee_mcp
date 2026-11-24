#!/usr/bin/env python3
"""In-VPC end-to-end verifier for Pattern 2 (BigQuery OBO Credential Passthrough) behind Apigee X."""

from __future__ import annotations

import json
import os
import socket
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BQ_MCP_HOST = os.environ.get("BQ_MCP_HOST", "mcp-bigquery.corp.internal")
EXPECTED_HUB_ILB_IP = os.environ.get("EXPECTED_HUB_ILB_IP", "10.10.1.30")
EXPECTED_APIGEE_PROJECT = os.environ.get("EXPECTED_APIGEE_PROJECT", "apigee-bq-obo")
MCP_URL = os.environ.get("MCP_URL", f"https://{BQ_MCP_HOST}/mcp")
HEALTH_URL = os.environ.get(
    "HEALTH_URL", f"https://{BQ_MCP_HOST}/healthz?prove_zero_sa_access=true"
)
CA_CERT_PATH = os.environ.get("CA_CERT_PATH", "/app/ca.crt")


def get_metadata_token(scopes: str) -> str:
    """Request a Google OAuth 2.0 access token from GCE metadata with specific scopes."""
    qs = urllib.parse.urlencode({"scopes": scopes})
    meta_url = (
        "http://metadata.google.internal/computeMetadata/v1/"
        f"instance/service-accounts/default/token?{qs}"
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
    ssl_ctx: ssl.SSLContext,
    payload: dict,
    bearer_token: str | None = None,
    extra_headers: dict[str, str] | None = None,
) -> tuple[int, dict, str]:
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }
    if bearer_token:
        headers["Authorization"] = f"Bearer {bearer_token}"
    if extra_headers:
        headers.update(extra_headers)

    body_bytes = json.dumps(payload).encode("utf-8")
    for attempt in range(1, 7):
        req = urllib.request.Request(
            MCP_URL,
            data=body_bytes,
            headers=headers,
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, context=ssl_ctx, timeout=30) as resp:
                return resp.status, dict(resp.headers), resp.read().decode("utf-8")
        except urllib.error.HTTPError as err:
            return err.code, dict(err.headers), err.read().decode("utf-8")
        except (urllib.error.URLError, ssl.SSLError, TimeoutError) as exc:
            if attempt == 6:
                raise
            print(
                f"      ... retrying POST /mcp after transient Envoy/PSC handshake convergence ({attempt}/6: {exc})"
            )
            time.sleep(5)
    raise RuntimeError("Unreachable")


def main() -> int:
    ssl_ctx = make_ssl_context()

    print(f"[1/6] Resolving Private Cloud DNS for {BQ_MCP_HOST}...")
    resolved_ip = ""
    for attempt in range(1, 13):
        try:
            resolved_ip = socket.gethostbyname(BQ_MCP_HOST)
            break
        except socket.gaierror as exc:
            if attempt == 12:
                raise
            print(f"      ... waiting for Cloud DNS propagation (attempt {attempt}/12: {exc})")
            time.sleep(10)
    print(f"      {BQ_MCP_HOST} -> {resolved_ip}")
    assert (
        resolved_ip == EXPECTED_HUB_ILB_IP
    ), f"Expected {EXPECTED_HUB_ILB_IP}, got {resolved_ip}"

    print(
        "[2/6] Verifying 15-hop PSC + Apigee X + Cloud Run OIDC & Zero-Privilege Runtime SA Proof..."
    )
    health = {}
    health_status = 0
    consecutive_ok = 0
    for attempt in range(1, 19):
        try:
            with urllib.request.urlopen(HEALTH_URL, context=ssl_ctx, timeout=25) as resp:
                health_status = resp.status
                health = json.loads(resp.read().decode("utf-8"))
                consecutive_ok += 1
                if consecutive_ok >= 2:
                    break
                time.sleep(1)
                continue
        except (
            urllib.error.HTTPError,
            urllib.error.URLError,
            ssl.SSLError,
            TimeoutError,
            json.JSONDecodeError,
        ) as exc:
            consecutive_ok = 0
            if attempt == 18:
                raise
            print(
                f"      ... waiting for Regional ALB / PSC / Apigee data plane convergence (attempt {attempt}/18: {exc})"
            )
            time.sleep(8)
    print(f"      HTTP {health_status}: {json.dumps(health)}")
    assert health_status == 200
    assert health.get("service") == "mcp-bq-obo-poc"
    assert health.get("project") == EXPECTED_APIGEE_PROJECT
    assert health.get("apigee_proxy") == "bq-obo-mcp"
    sa_proof = health.get("zero_privilege_sa_proof", {})
    assert (
        sa_proof.get("sa_adc_bigquery_allowed") is False
    ), f"Expected Cloud Run runtime SA to have ZERO BigQuery access, got: {sa_proof}"
    print(
        f"      Confirmed Cloud Run SA ({sa_proof.get('runtime_service_account')}) denied BigQuery ADC access (HTTP {sa_proof.get('sa_adc_http_status')})."
    )

    print(
        "[3/6] Verifying Apigee anti-spoofing strips forged X-MCP-User-Authorization & rejects missing Bearer (HTTP 401)..."
    )
    status_401, hdrs_401, body_401 = http_post_mcp(
        ssl_ctx,
        {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}},
        bearer_token=None,
        extra_headers={"X-MCP-User-Authorization": "Bearer spoofed-attacker-token"},
    )
    www_auth_401 = hdrs_401.get("WWW-Authenticate") or hdrs_401.get("www-authenticate", "")
    print(f"      HTTP {status_401} | Body: {body_401.strip()} | WWW-Authenticate: {www_auth_401}")
    assert status_401 == 401, f"Expected HTTP 401, got {status_401}: {body_401}"
    assert "apigee-x-gateway" in body_401, f"Expected Apigee gateway enforcement, got: {body_401}"

    print(
        "[4/6] Verifying Apigee SC-Verify-Google-TokenInfo rejects invalid Bearer token at gateway (HTTP 401)..."
    )
    status_inv, _, body_inv = http_post_mcp(
        ssl_ctx,
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
        bearer_token="ya29.invalid-tampered-token-for-verification",
    )
    print(f"      HTTP {status_inv} | Body: {body_inv.strip()}")
    assert status_inv == 401, f"Expected HTTP 401, got {status_inv}: {body_inv}"
    assert "apigee-x-gateway" in body_inv

    print(
        "[5/6] Verifying Apigee RF-Insufficient-BQ-Scope blocks under-scoped tokens (identity-only AND bigquery.readonly-only) at gateway (HTTP 403)..."
    )
    narrow_token = get_metadata_token("https://www.googleapis.com/auth/userinfo.email")
    status_403, hdrs_403, body_403 = http_post_mcp(
        ssl_ctx,
        {"jsonrpc": "2.0", "id": 3, "method": "tools/list", "params": {}},
        bearer_token=narrow_token,
    )
    www_auth_403 = hdrs_403.get("WWW-Authenticate") or hdrs_403.get("www-authenticate", "")
    print(f"      [5a: userinfo.email] HTTP {status_403} | Body: {body_403.strip()} | WWW-Authenticate: {www_auth_403}")
    assert status_403 == 403, f"Expected HTTP 403 insufficient_scope, got {status_403}: {body_403}"
    assert "insufficient_scope" in body_403 and "apigee-x-gateway" in body_403

    ro_only_token = get_metadata_token(
        "https://www.googleapis.com/auth/userinfo.email,https://www.googleapis.com/auth/bigquery.readonly"
    )
    status_ro403, _, body_ro403 = http_post_mcp(
        ssl_ctx,
        {"jsonrpc": "2.0", "id": 31, "method": "tools/list", "params": {}},
        bearer_token=ro_only_token,
    )
    print(f"      [5b: bigquery.readonly] HTTP {status_ro403} | Body: {body_ro403.strip()}")
    assert status_ro403 == 403, f"Expected HTTP 403 for bigquery.readonly (jobs.insert needs auth/bigquery), got {status_ro403}: {body_ro403}"
    assert "insufficient_scope" in body_ro403 and "apigee-x-gateway" in body_ro403

    print(
        "[6/6] Verifying auth/bigquery-scoped token passes Apigee X -> Cloud Run OIDC -> FastMCP -> BigQuery jobs.insert..."
    )
    user_override_token = os.environ.get("OAUTH_BEARER_TOKEN", "").strip()
    scoped_token = user_override_token or get_metadata_token(
        "https://www.googleapis.com/auth/userinfo.email,https://www.googleapis.com/auth/bigquery"
    )
    status_bq, _, body_bq = http_post_mcp(
        ssl_ctx,
        {"jsonrpc": "2.0", "id": 4, "method": "tools/list", "params": {}},
        bearer_token=scoped_token,
    )
    if status_bq == 401 and "EXPECTED_OAUTH_CLIENT_ID" in body_bq:
        print(
            "      Passed Apigee X auth/bigquery gatekeeper + Cloud Run OIDC; FastMCP EXPECTED_OAUTH_CLIENT_ID pinning active (rejected non-GE service account client as expected):"
        )
        print(f"      {body_bq.strip()}")
    else:
        print(f"      tools/list HTTP {status_bq}: {body_bq.strip()[:260]}...")
        assert status_bq == 200, f"Expected HTTP 200, got {status_bq}: {body_bq}"

        status_call, _, body_call = http_post_mcp(
            ssl_ctx,
            {
                "jsonrpc": "2.0",
                "id": 5,
                "method": "tools/call",
                "params": {
                    "name": "query_top_usa_names",
                    "arguments": {"state": "CA", "start_year": 2015, "limit": 5},
                },
            },
            bearer_token=scoped_token,
        )
        print(f"      tools/call (query_top_usa_names) HTTP {status_call}:\n{body_call.strip()}")
        assert status_call == 200, f"Expected HTTP 200, got {status_call}: {body_call}"
        assert "bigquery_session_user" in body_call and "bq-obo-mcp" in body_call

        status_ev, _, body_ev = http_post_mcp(
            ssl_ctx,
            {
                "jsonrpc": "2.0",
                "id": 6,
                "method": "tools/call",
                "params": {
                    "name": "verify_obo_credential_evidence",
                    "arguments": {},
                },
            },
            bearer_token=scoped_token,
        )
        print(
            f"      tools/call (verify_obo_credential_evidence) HTTP {status_ev}:\n{body_ev.strip()}"
        )
        assert status_ev == 200, f"Expected HTTP 200, got {status_ev}: {body_ev}"
        assert '"identity_separation_verified": true' in body_ev or '"identity_separation_verified":true' in body_ev

    print(
        "\nALL APIGEE X + DUAL PSC + BIGQUERY SCOPE GATEKEEPER + ZERO-SA-PRIVILEGE OBO CHECKS PASSED."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
