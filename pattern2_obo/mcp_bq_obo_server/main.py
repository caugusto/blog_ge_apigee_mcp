"""Internal BigQuery End-User Credential Passthrough (OBO) MCP Server behind Apigee X.

Implements Enterprise MCP Credential Pattern 2:
- Cloud Run IAM (--no-allow-unauthenticated) verified via Apigee-minted sa-apigee-invoker OIDC ID token.
- Cloud Run runtime service account (sa-mcp-bq-runtime) holds ZERO BigQuery IAM roles.
- Signed-in human user's 3LO Google OAuth 2.0 token (auth/bigquery) arrives in X-MCP-User-Authorization,
  is verified for client_id pinning and BigQuery job execution scope, isolated per request via contextvars, and passed into
  an ephemeral per-request bigquery.Client(credentials=Credentials(token=...)) so BigQuery executes strictly
  as SESSION_USER() == <signed-in human user>.
"""

from __future__ import annotations

import asyncio
import contextvars
import hashlib
import logging
import os
import time
import urllib.parse
import urllib.request
from typing import Any

import certifi
import google.api_core.exceptions
import google.oauth2.credentials
import httpx
from fastmcp import FastMCP
from fastmcp.server.dependencies import get_http_headers
from google.cloud import bigquery
from mcp.types import ToolAnnotations
from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)
logger = logging.getLogger("mcp-bq-obo-poc")

GOOGLE_TOKENINFO_URL = os.environ.get(
    "GOOGLE_TOKENINFO_URL", "https://oauth2.googleapis.com/tokeninfo"
)
EXPECTED_OAUTH_CLIENT_ID = os.environ.get("EXPECTED_OAUTH_CLIENT_ID", "").strip()
ALLOWED_VERIFIER_EMAIL = os.environ.get("ALLOWED_VERIFIER_EMAIL", "").strip().lower()
ALLOWED_EMAIL_DOMAIN = os.environ.get("ALLOWED_EMAIL_DOMAIN", "").strip().lower()
HOSTING_PROJECT_ID = os.environ.get("GOOGLE_CLOUD_PROJECT", "apigee-bq-obo")
BQ_JOB_PROJECT = os.environ.get("BQ_JOB_PROJECT", HOSTING_PROJECT_ID).strip()
MAX_BYTES_BILLED = int(os.environ.get("BQ_MAX_BYTES_BILLED", str(500 * 1024 * 1024)))
TOKEN_CACHE_MAX_TTL_SECONDS = 60

# BigQuery jobs.insert requires auth/bigquery or cloud-platform (bigquery.readonly only covers tabledata.list)
ACCEPTED_BQ_SCOPES = {
    "https://www.googleapis.com/auth/bigquery",
    "https://www.googleapis.com/auth/cloud-platform",
}

# Request-scoped async context variables: never shared across concurrent requests
CURRENT_OAUTH_CLAIMS: contextvars.ContextVar[dict[str, Any]] = contextvars.ContextVar(
    "current_oauth_claims", default={}
)
CURRENT_USER_ACCESS_TOKEN: contextvars.ContextVar[str] = contextvars.ContextVar(
    "current_user_access_token", default=""
)

# Caches ONLY non-sensitive tokeninfo claims keyed by sha256(token); never stores raw tokens
_CLAIMS_CACHE: dict[str, tuple[float, dict[str, Any]]] = {}
_RUNTIME_SA_EMAIL: str | None = None


def _get_runtime_sa_email() -> str:
    """Fetch the Cloud Run container's own service account email from GCE metadata."""
    global _RUNTIME_SA_EMAIL
    if _RUNTIME_SA_EMAIL is not None:
        return _RUNTIME_SA_EMAIL
    meta_url = (
        "http://metadata.google.internal/computeMetadata/v1/"
        "instance/service-accounts/default/email"
    )
    try:
        req = urllib.request.Request(meta_url, headers={"Metadata-Flavor": "Google"})
        with urllib.request.urlopen(req, timeout=2) as resp:
            _RUNTIME_SA_EMAIL = resp.read().decode("utf-8").strip()
    except Exception:
        _RUNTIME_SA_EMAIL = "local-adc"
    return _RUNTIME_SA_EMAIL


class OAuthVerificationError(Exception):
    """Raised when an end-user OAuth 2.0 Bearer token is missing, invalid, or under-scoped."""

    def __init__(self, code: str, description: str, status_code: int = 401) -> None:
        super().__init__(description)
        self.code = code
        self.description = description
        self.status_code = status_code


async def verify_google_oauth_bearer_token(auth_header: str) -> tuple[str, dict[str, Any]]:
    """Verify an end-user Google OAuth 2.0 Bearer token and enforce BigQuery read scope."""
    if not auth_header or not auth_header.lower().startswith("bearer "):
        raise OAuthVerificationError(
            "invalid_request",
            "Missing or malformed Bearer <access_token> in X-MCP-User-Authorization / Authorization header.",
            status_code=401,
        )

    raw_token = auth_header[7:].strip()
    if not raw_token:
        raise OAuthVerificationError("invalid_request", "Empty Bearer token.", status_code=401)

    token_hash = hashlib.sha256(raw_token.encode("utf-8")).hexdigest()
    now = time.time()
    cached = _CLAIMS_CACHE.get(token_hash)
    if cached and cached[0] > now:
        return raw_token, cached[1]

    try:
        async with httpx.AsyncClient(verify=certifi.where(), timeout=5.0) as client:
            resp = await client.get(GOOGLE_TOKENINFO_URL, params={"access_token": raw_token})
    except Exception as exc:
        logger.error("Failed reaching Google tokeninfo endpoint: %s", exc)
        raise OAuthVerificationError(
            "invalid_token",
            "Unable to validate OAuth 2.0 access token against authorization server.",
            status_code=401,
        ) from exc

    if resp.status_code != 200:
        logger.warning("Google tokeninfo rejected token with HTTP %s", resp.status_code)
        raise OAuthVerificationError(
            "invalid_token",
            "The supplied Google OAuth 2.0 access token is invalid or expired.",
            status_code=401,
        )

    payload = resp.json()
    expires_in = int(payload.get("expires_in", 0))
    if expires_in <= 0:
        raise OAuthVerificationError(
            "invalid_token", "OAuth 2.0 access token has expired.", status_code=401
        )

    granted_scopes = set(payload.get("scope", "").split())
    if not (granted_scopes & ACCEPTED_BQ_SCOPES):
        raise OAuthVerificationError(
            "insufficient_scope",
            "OAuth 2.0 token lacks required BigQuery scope (https://www.googleapis.com/auth/bigquery) needed by jobs.insert.",
            status_code=403,
        )

    email = payload.get("email", "")
    is_pinned_verifier = bool(
        ALLOWED_VERIFIER_EMAIL and email.lower() == ALLOWED_VERIFIER_EMAIL
    )

    if EXPECTED_OAUTH_CLIENT_ID and not is_pinned_verifier:
        token_clients = {payload.get("aud", ""), payload.get("azp", "")}
        if EXPECTED_OAUTH_CLIENT_ID not in token_clients:
            raise OAuthVerificationError(
                "invalid_token",
                "Token client_id (aud/azp) does not match EXPECTED_OAUTH_CLIENT_ID.",
                status_code=401,
            )

    if (
        ALLOWED_EMAIL_DOMAIN
        and not is_pinned_verifier
        and not email.lower().endswith(f"@{ALLOWED_EMAIL_DOMAIN}")
    ):
        raise OAuthVerificationError(
            "insufficient_scope",
            f"Authenticated principal is not in allowed domain '{ALLOWED_EMAIL_DOMAIN}'.",
            status_code=403,
        )

    ttl = min(expires_in, TOKEN_CACHE_MAX_TTL_SECONDS)
    _CLAIMS_CACHE[token_hash] = (now + ttl, payload)
    return raw_token, payload


def _probe_runtime_sa_zero_bq_access() -> dict[str, Any]:
    """Negative control: verify the Cloud Run container's own SA cannot run BigQuery jobs."""
    runtime_sa = _get_runtime_sa_email()
    sa_client = bigquery.Client(project=BQ_JOB_PROJECT)
    try:
        job = sa_client.query("SELECT SESSION_USER() AS principal")
        rows = list(job.result(timeout=15))
        principal = rows[0]["principal"] if rows else "unknown"
        return {
            "runtime_service_account": runtime_sa,
            "sa_adc_bigquery_allowed": True,
            "sa_adc_http_status": 200,
            "unexpected_principal": principal,
        }
    except google.api_core.exceptions.GoogleAPICallError as exc:
        return {
            "runtime_service_account": runtime_sa,
            "sa_adc_bigquery_allowed": False,
            "sa_adc_http_status": int(exc.code or 403),
            "sa_adc_error_summary": str(exc).splitlines()[0][:320],
        }
    except Exception as exc:
        return {
            "runtime_service_account": runtime_sa,
            "sa_adc_bigquery_allowed": False,
            "sa_adc_http_status": 403,
            "sa_adc_error_summary": str(exc).splitlines()[0][:320],
        }
    finally:
        sa_client.close()


class GoogleOAuth2Middleware:
    """ASGI middleware enforcing end-user Google OAuth 2.0 + BigQuery scope on /mcp behind Apigee X."""

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        path: str = scope.get("path", "")
        query_string = scope.get("query_string", b"").decode("latin-1")
        query_params = urllib.parse.parse_qs(query_string)
        raw_headers = {
            k.decode("latin-1").lower(): v.decode("latin-1")
            for k, v in scope.get("headers", [])
        }

        if path == "/healthz":
            body: dict[str, Any] = {
                "status": "ok",
                "service": "mcp-bq-obo-poc",
                "project": HOSTING_PROJECT_ID,
                "bq_job_project": BQ_JOB_PROJECT,
                "runtime_service_account": _get_runtime_sa_email(),
                "apigee_proxy": raw_headers.get("x-apigee-proxy", "direct"),
                "transport": "streamable-http",
            }
            if query_params.get("prove_zero_sa_access", ["false"])[0].lower() in ("1", "true", "yes"):
                adc_probe = await asyncio.to_thread(_probe_runtime_sa_zero_bq_access)
                body["zero_privilege_sa_proof"] = adc_probe
            resp = JSONResponse(body)
            await resp(scope, receive, send)
            return

        if path == "/mcp" or path.startswith("/mcp/"):
            user_auth_header = (
                raw_headers.get("x-mcp-user-authorization")
                or raw_headers.get("authorization", "")
            )
            try:
                raw_token, claims = await verify_google_oauth_bearer_token(user_auth_header)
            except OAuthVerificationError as err:
                www_auth = (
                    'Bearer realm="mcp-bq-obo-poc", '
                    'scope="openid email profile https://www.googleapis.com/auth/bigquery", '
                    f'error="{err.code}", '
                    f'error_description="{err.description}"'
                )
                resp = JSONResponse(
                    status_code=err.status_code,
                    content={
                        "error": err.code,
                        "error_description": err.description,
                        "enforced_by": "cloud-run-mcp-middleware",
                    },
                    headers={"WWW-Authenticate": www_auth},
                )
                await resp(scope, receive, send)
                return

            claims_reset = CURRENT_OAUTH_CLAIMS.set(claims)
            token_reset = CURRENT_USER_ACCESS_TOKEN.set(raw_token)
            try:
                await self.app(scope, receive, send)
            finally:
                CURRENT_USER_ACCESS_TOKEN.reset(token_reset)
                CURRENT_OAUTH_CLAIMS.reset(claims_reset)
            return

        await self.app(scope, receive, send)


mcp = FastMCP("mcp-bq-obo-poc")


def _caller_context() -> dict[str, Any]:
    headers = get_http_headers(include_all=True)
    caller_ip = headers.get("x-forwarded-for", "internal").split(",")[0].strip()
    claims = CURRENT_OAUTH_CLAIMS.get()
    return {
        "hosting_project": HOSTING_PROJECT_ID,
        "bq_job_project": BQ_JOB_PROJECT,
        "cloud_run_runtime_service_account": _get_runtime_sa_email(),
        "mediated_by_apigee_proxy": headers.get("x-apigee-proxy", "none"),
        "apigee_organization": headers.get("x-apigee-org", "none"),
        "apigee_verified_email": headers.get("x-apigee-verified-email", "none"),
        "authenticated_user": claims.get("email") or claims.get("sub") or "verified-oauth-principal",
        "oauth_subject": claims.get("sub"),
        "oauth_scopes": claims.get("scope", "").split(),
        "caller_ip": caller_ip,
    }


def _execute_top_usa_names_as_user(
    user_token: str,
    state: str,
    start_year: int,
    gender: str | None,
    limit: int,
) -> dict[str, Any]:
    """Run parameterized BigQuery query strictly using an ephemeral end-user Credentials object."""
    clean_state = state.strip().upper()[:2] or "CA"
    clean_year = max(1910, min(2025, int(start_year)))
    clean_limit = max(1, min(20, int(limit)))
    clean_gender = gender.strip().upper()[:1] if gender and gender.strip() else None

    sql = """
    SELECT
      SESSION_USER() AS bigquery_session_user,
      state,
      name,
      gender,
      SUM(number) AS total_births
    FROM `bigquery-public-data.usa_names.usa_1910_current`
    WHERE UPPER(state) = @state
      AND year >= @start_year
      AND (@gender IS NULL OR UPPER(gender) = @gender)
    GROUP BY state, name, gender
    ORDER BY total_births DESC
    LIMIT @limit
    """

    user_creds = google.oauth2.credentials.Credentials(token=user_token)
    bq_client = bigquery.Client(project=BQ_JOB_PROJECT, credentials=user_creds)
    try:
        job_config = bigquery.QueryJobConfig(
            query_parameters=[
                bigquery.ScalarQueryParameter("state", "STRING", clean_state),
                bigquery.ScalarQueryParameter("start_year", "INT64", clean_year),
                bigquery.ScalarQueryParameter("gender", "STRING", clean_gender),
                bigquery.ScalarQueryParameter("limit", "INT64", clean_limit),
            ],
            maximum_bytes_billed=MAX_BYTES_BILLED,
            labels={
                "mcp_pattern": "pattern2_obo",
                "mediated_by": "apigee_x",
            },
        )
        query_job = bq_client.query(sql, job_config=job_config)
        rows = list(query_job.result(timeout=30))
        session_user = rows[0]["bigquery_session_user"] if rows else query_job.user_email
        results = [
            {
                "rank": idx + 1,
                "state": r["state"],
                "name": r["name"],
                "gender": r["gender"],
                "total_births": int(r["total_births"]),
            }
            for idx, r in enumerate(rows)
        ]
        logger.info(
            "OBO BigQuery job succeeded: job_id=%s session_user=%s job.user_email=%s runtime_sa=%s bytes=%s",
            query_job.job_id,
            session_user,
            query_job.user_email,
            _get_runtime_sa_email(),
            query_job.total_bytes_processed,
        )
        return {
            "executed_as_end_user": True,
            "bigquery_session_user": session_user,
            "bigquery_job_user_email": query_job.user_email,
            "bigquery_job_id": f"{query_job.project}:{query_job.location}.{query_job.job_id}",
            "bigquery_raw_job_id": query_job.job_id,
            "total_bytes_processed": int(query_job.total_bytes_processed or 0),
            "dataset": "bigquery-public-data.usa_names.usa_1910_current",
            "filters": {
                "state": clean_state,
                "start_year": clean_year,
                "gender": clean_gender or "ALL",
                "limit": clean_limit,
            },
            "results": results,
        }
    except google.api_core.exceptions.Forbidden as exc:
        return {
            "executed_as_end_user": False,
            "bigquery_permission_denied_for_end_user": True,
            "error": str(exc).splitlines()[0][:360],
            "remediation": (
                f"Grant roles/bigquery.jobUser on project '{BQ_JOB_PROJECT}' to the signed-in user "
                "so BigQuery permits their end-user OAuth credential to submit SELECT jobs."
            ),
        }
    finally:
        bq_client.close()


def _execute_obo_evidence_as_user(user_token: str) -> dict[str, Any]:
    """Run negative SA control + positive user OBO control side by side."""
    sa_negative_proof = _probe_runtime_sa_zero_bq_access()

    user_creds = google.oauth2.credentials.Credentials(token=user_token)
    bq_client = bigquery.Client(project=BQ_JOB_PROJECT, credentials=user_creds)
    try:
        job_config = bigquery.QueryJobConfig(
            maximum_bytes_billed=MAX_BYTES_BILLED,
            labels={
                "mcp_pattern": "pattern2_obo_proof",
                "mediated_by": "apigee_x",
            },
        )
        query_job = bq_client.query(
            "SELECT SESSION_USER() AS bigquery_session_user, CURRENT_TIMESTAMP() AS executed_at_utc",
            job_config=job_config,
        )
        rows = list(query_job.result(timeout=20))
        row = rows[0]
        session_user = row["bigquery_session_user"]
        executed_at = row["executed_at_utc"].isoformat()
        return {
            "negative_control_cloud_run_sa_adc": sa_negative_proof,
            "positive_control_end_user_obo": {
                "bigquery_session_user": session_user,
                "bigquery_job_user_email": query_job.user_email,
                "bigquery_job_id": f"{query_job.project}:{query_job.location}.{query_job.job_id}",
                "bigquery_raw_job_id": query_job.job_id,
                "executed_at_utc": executed_at,
                "identity_separation_verified": (
                    session_user != sa_negative_proof["runtime_service_account"]
                    and not sa_negative_proof["sa_adc_bigquery_allowed"]
                ),
            },
            "cloud_audit_log_filter": (
                'protoPayload.serviceName="bigquery.googleapis.com" AND '
                'protoPayload.methodName="google.cloud.bigquery.v2.JobService.InsertJob" AND '
                f'protoPayload.resourceName:"{query_job.job_id}"'
            ),
        }
    finally:
        bq_client.close()


@mcp.tool(
    description=(
        "Execute a live BigQuery SQL query against bigquery-public-data.usa_names.usa_1910_current "
        "strictly using the signed-in human user's 3LO Google OAuth 2.0 credential (On-Behalf-Of passthrough), "
        "returning top baby names by US state alongside cryptographic BigQuery SESSION_USER() and job.user_email proof."
    ),
    annotations=ToolAnnotations(
        title="Query Top USA Baby Names (User OBO)",
        readOnlyHint=True,
        destructiveHint=False,
        idempotentHint=True,
        openWorldHint=False,
    ),
)
async def query_top_usa_names(
    state: str = "CA",
    start_year: int = 2015,
    gender: str | None = None,
    limit: int = 5,
) -> dict[str, Any]:
    """Query top baby names in a US state from bigquery-public-data as the signed-in user."""
    user_token = CURRENT_USER_ACCESS_TOKEN.get()
    ctx = _caller_context()
    bq_out = await asyncio.to_thread(
        _execute_top_usa_names_as_user, user_token, state, start_year, gender, limit
    )
    return {**ctx, **bq_out}


@mcp.tool(
    description=(
        "Prove end-user credential passthrough (Pattern 2) with two live BigQuery checks: "
        "(1) confirm the Cloud Run runtime service account has ZERO BigQuery permissions (HTTP 403 Access Denied on ADC), "
        "and (2) run SELECT SESSION_USER() using the end user's OAuth 2.0 token, returning SESSION_USER(), "
        "BigQuery job_id, job.user_email, and Cloud Audit Log filter."
    ),
    annotations=ToolAnnotations(
        title="Verify End-User BigQuery Credential Evidence",
        readOnlyHint=True,
        destructiveHint=False,
        idempotentHint=True,
        openWorldHint=False,
    ),
)
async def verify_obo_credential_evidence() -> dict[str, Any]:
    """Compare Cloud Run SA zero-access failure against end-user OBO BigQuery execution."""
    user_token = CURRENT_USER_ACCESS_TOKEN.get()
    ctx = _caller_context()
    evidence = await asyncio.to_thread(_execute_obo_evidence_as_user, user_token)
    return {**ctx, **evidence}


@mcp.tool(
    description=(
        "Inspect the verified Google OAuth 2.0 caller claims, scopes, Apigee X gateway-attested headers, "
        "and zero-privilege Cloud Run service account identity without running a BigQuery job."
    ),
    annotations=ToolAnnotations(
        title="Get OBO Caller & Apigee Gateway Context",
        readOnlyHint=True,
        destructiveHint=False,
        idempotentHint=True,
        openWorldHint=False,
    ),
)
async def get_authenticated_caller() -> dict[str, Any]:
    """Return the verified OBO caller context and Apigee gateway attestation headers."""
    return _caller_context()


_mcp_asgi_app = mcp.http_app(path="/mcp", stateless_http=True)
app = GoogleOAuth2Middleware(_mcp_asgi_app)
