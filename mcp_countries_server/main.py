"""Internal Country Facts MCP Server behind Apigee X (StreamableHTTP + Google OAuth 2.0 + Cloud Run IAM)."""

from __future__ import annotations

import contextvars
import hashlib
import logging
import os
import time
from typing import Any

import certifi
import httpx
from fastmcp import FastMCP
from fastmcp.server.dependencies import get_http_headers
from mcp.types import ToolAnnotations
from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)
logger = logging.getLogger("mcp-countries-poc")

GOOGLE_TOKENINFO_URL = os.environ.get(
    "GOOGLE_TOKENINFO_URL", "https://oauth2.googleapis.com/tokeninfo"
)
EXPECTED_OAUTH_CLIENT_ID = os.environ.get("EXPECTED_OAUTH_CLIENT_ID", "").strip()
ALLOWED_EMAIL_DOMAIN = os.environ.get("ALLOWED_EMAIL_DOMAIN", "").strip().lower()
HOSTING_PROJECT_ID = os.environ.get("GOOGLE_CLOUD_PROJECT", "apigee-x-mcp")
TOKEN_CACHE_MAX_TTL_SECONDS = 60

CURRENT_OAUTH_CLAIMS: contextvars.ContextVar[dict[str, Any]] = contextvars.ContextVar(
    "current_oauth_claims", default={}
)

_TOKEN_CACHE: dict[str, tuple[float, dict[str, Any]]] = {}

COUNTRY_CATALOG: dict[str, dict[str, Any]] = {
    "japan": {
        "country_id": "japan",
        "iso_alpha3": "JPN",
        "name": "Japan",
        "region": "Asia",
        "capital": "Tokyo",
        "population_millions": 124.5,
        "currency": "Japanese Yen (JPY)",
        "official_languages": ["Japanese"],
        "timezones": ["UTC+09:00"],
        "facts": [
            "Japan is an archipelago comprising 14,125 officially mapped islands following its 2023 digital coast guard survey.",
            "The Shinkansen high-speed rail network has carried over 10 billion passengers since 1964 with zero passenger fatalities from derailments or collisions.",
            "Japan is home to Kongo Gumi (founded in 578 AD) and Nishiyama Onsen Keiunkan (705 AD), among the oldest continuously operating businesses in the world.",
        ],
    },
    "brazil": {
        "country_id": "brazil",
        "iso_alpha3": "BRA",
        "name": "Brazil",
        "region": "Americas",
        "capital": "Brasilia",
        "population_millions": 203.1,
        "currency": "Brazilian Real (BRL)",
        "official_languages": ["Portuguese"],
        "timezones": ["UTC-05:00", "UTC-04:00", "UTC-03:00", "UTC-02:00"],
        "facts": [
            "Brazil shares a land border with every South American country except Chile and Ecuador.",
            "Roughly 60% of the Amazon Rainforest lies within Brazil, housing an estimated 10% of all known species on Earth.",
            "Brasilia was purpose-built in just 41 months (1956-1960) with an urban layout designed by Lucio Costa and Oscar Niemeyer.",
        ],
    },
    "norway": {
        "country_id": "norway",
        "iso_alpha3": "NOR",
        "name": "Norway",
        "region": "Europe",
        "capital": "Oslo",
        "population_millions": 5.55,
        "currency": "Norwegian Krone (NOK)",
        "official_languages": ["Norwegian (Bokmal & Nynorsk)", "Sami"],
        "timezones": ["UTC+01:00"],
        "facts": [
            "Including fjords and islands, Norway's coastline stretches over 100,000 kilometers, more than twice Earth's equatorial circumference.",
            "Over 98% of Norway's domestic electricity generation comes from renewable sources, predominantly hydropower.",
            "Norway hosts the Svalbard Global Seed Vault inside a permafrost mountain on Spitsbergen island, safeguarding over 1.2 million crop seed samples.",
        ],
    },
    "kenya": {
        "country_id": "kenya",
        "iso_alpha3": "KEN",
        "name": "Kenya",
        "region": "Africa",
        "capital": "Nairobi",
        "population_millions": 55.1,
        "currency": "Kenyan Shilling (KES)",
        "official_languages": ["Swahili", "English"],
        "timezones": ["UTC+03:00"],
        "facts": [
            "Nairobi is the only capital city in the world with a full wildlife national park (Nairobi National Park) bordering its metropolitan skyline.",
            "Roughly 90% of Kenya's grid electricity is generated from renewables, led by East Africa Rift Valley geothermal power.",
            "Kenya pioneered mobile money globally with the launch of M-Pesa in 2007, expanding financial access across East Africa.",
        ],
    },
    "canada": {
        "country_id": "canada",
        "iso_alpha3": "CAN",
        "name": "Canada",
        "region": "Americas",
        "capital": "Ottawa",
        "population_millions": 40.8,
        "currency": "Canadian Dollar (CAD)",
        "official_languages": ["English", "French"],
        "timezones": [
            "UTC-08:00",
            "UTC-07:00",
            "UTC-06:00",
            "UTC-05:00",
            "UTC-04:00",
            "UTC-03:30",
        ],
        "facts": [
            "Canada contains more lakes than the rest of the world's countries combined, with over 60% of all lakes on Earth.",
            "Its 243,042 km coastline along the Pacific, Arctic, and Atlantic oceans is the longest of any country in the world.",
            "Alert, Nunavut on Ellesmere Island (82.5 N) is the northernmost permanently inhabited place on Earth.",
        ],
    },
    "australia": {
        "country_id": "australia",
        "iso_alpha3": "AUS",
        "name": "Australia",
        "region": "Oceania",
        "capital": "Canberra",
        "population_millions": 26.9,
        "currency": "Australian Dollar (AUD)",
        "official_languages": ["English"],
        "timezones": ["UTC+08:00", "UTC+09:30", "UTC+10:00"],
        "facts": [
            "Australia is the only nation-state that governs an entire continental landmass and sits on a fast-moving continental tectonic plate (~7 cm/year northward).",
            "Over 80% of Australia's mammals, reptiles, and frogs are endemic and found nowhere else on Earth.",
            "The Great Barrier Reef off Queensland spans over 2,300 kilometers and is the largest living structure visible from space.",
        ],
    },
}


class OAuthVerificationError(Exception):
    """Raised when an end-user OAuth 2.0 Bearer token is missing or invalid."""

    def __init__(self, code: str, description: str) -> None:
        super().__init__(description)
        self.code = code
        self.description = description


async def verify_google_oauth_bearer_token(auth_header: str) -> dict[str, Any]:
    """Verify an end-user OAuth 2.0 Bearer access token against Google's tokeninfo endpoint."""
    if not auth_header or not auth_header.lower().startswith("bearer "):
        raise OAuthVerificationError(
            "invalid_request",
            "Missing or malformed Bearer <access_token> in X-MCP-User-Authorization / Authorization header.",
        )

    token = auth_header[7:].strip()
    if not token:
        raise OAuthVerificationError(
            "invalid_request",
            "Empty Bearer token.",
        )

    token_hash = hashlib.sha256(token.encode("utf-8")).hexdigest()
    now = time.time()
    cached = _TOKEN_CACHE.get(token_hash)
    if cached and cached[0] > now:
        return cached[1]

    try:
        async with httpx.AsyncClient(verify=certifi.where(), timeout=5.0) as client:
            resp = await client.get(GOOGLE_TOKENINFO_URL, params={"access_token": token})
    except Exception as exc:
        logger.error("Failed reaching Google tokeninfo endpoint: %s", exc)
        raise OAuthVerificationError(
            "invalid_token",
            "Unable to validate OAuth 2.0 access token against authorization server.",
        ) from exc

    if resp.status_code != 200:
        logger.warning("Google tokeninfo rejected token with HTTP %s", resp.status_code)
        raise OAuthVerificationError(
            "invalid_token",
            "The supplied Google OAuth 2.0 access token is invalid or expired.",
        )

    payload = resp.json()
    expires_in = int(payload.get("expires_in", 0))
    if expires_in <= 0:
        raise OAuthVerificationError("invalid_token", "OAuth 2.0 access token has expired.")

    if EXPECTED_OAUTH_CLIENT_ID:
        token_clients = {payload.get("aud", ""), payload.get("azp", "")}
        if EXPECTED_OAUTH_CLIENT_ID not in token_clients:
            raise OAuthVerificationError(
                "invalid_token",
                "Token client_id (aud/azp) does not match EXPECTED_OAUTH_CLIENT_ID.",
            )

    email = payload.get("email", "")
    if ALLOWED_EMAIL_DOMAIN:
        if not email.lower().endswith(f"@{ALLOWED_EMAIL_DOMAIN}"):
            raise OAuthVerificationError(
                "insufficient_scope",
                f"Authenticated principal is not in allowed domain '{ALLOWED_EMAIL_DOMAIN}'.",
            )

    ttl = min(expires_in, TOKEN_CACHE_MAX_TTL_SECONDS)
    _TOKEN_CACHE[token_hash] = (now + ttl, payload)
    return payload


class GoogleOAuth2Middleware:
    """ASGI middleware enforcing end-user Google OAuth 2.0 Bearer auth on /mcp behind Apigee X."""

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        path: str = scope.get("path", "")
        raw_headers = {
            k.decode("latin-1").lower(): v.decode("latin-1")
            for k, v in scope.get("headers", [])
        }

        if path == "/healthz":
            resp = JSONResponse(
                {
                    "status": "ok",
                    "service": "mcp-countries-poc",
                    "project": HOSTING_PROJECT_ID,
                    "apigee_proxy": raw_headers.get("x-apigee-proxy", "direct"),
                    "transport": "streamable-http",
                }
            )
            await resp(scope, receive, send)
            return

        if path == "/mcp" or path.startswith("/mcp/"):
            # Apigee X translates Cloud Run IAM OIDC into Authorization and preserves user OAuth2 in X-MCP-User-Authorization
            user_auth_header = (
                raw_headers.get("x-mcp-user-authorization")
                or raw_headers.get("authorization", "")
            )
            try:
                claims = await verify_google_oauth_bearer_token(user_auth_header)
            except OAuthVerificationError as err:
                www_auth = (
                    f'Bearer realm="mcp-countries-poc", '
                    f'error="{err.code}", '
                    f'error_description="{err.description}"'
                )
                resp = JSONResponse(
                    status_code=401,
                    content={
                        "error": err.code,
                        "error_description": err.description,
                    },
                    headers={"WWW-Authenticate": www_auth},
                )
                await resp(scope, receive, send)
                return

            ctx_token = CURRENT_OAUTH_CLAIMS.set(claims)
            try:
                await self.app(scope, receive, send)
            finally:
                CURRENT_OAUTH_CLAIMS.reset(ctx_token)
            return

        await self.app(scope, receive, send)


mcp = FastMCP("mcp-countries-poc")


def _caller_context() -> dict[str, Any]:
    headers = get_http_headers(include_all=True)
    caller_ip = headers.get("x-forwarded-for", "internal").split(",")[0].strip()
    apigee_proxy = headers.get("x-apigee-proxy", "none")
    apigee_org = headers.get("x-apigee-org", "none")
    claims = CURRENT_OAUTH_CLAIMS.get()
    return {
        "hosting_project": HOSTING_PROJECT_ID,
        "mediated_by_apigee_proxy": apigee_proxy,
        "apigee_organization": apigee_org,
        "authenticated_user": claims.get("email") or claims.get("sub") or "verified-oauth-principal",
        "oauth_subject": claims.get("sub"),
        "oauth_scopes": claims.get("scope", "").split(),
        "caller_ip": caller_ip,
    }


@mcp.tool(
    description="List countries in the Country Facts catalog with ISO codes, capitals, regions, populations, currencies, and headline facts.",
    annotations=ToolAnnotations(
        title="List Countries",
        readOnlyHint=True,
        destructiveHint=False,
        idempotentHint=True,
        openWorldHint=False,
    ),
)
def list_countries(region: str | None = None) -> dict[str, Any]:
    """List countries in the catalog, optionally filtered by geographic region (Asia, Americas, Europe, Africa, Oceania)."""
    countries = list(COUNTRY_CATALOG.values())
    if region:
        reg_lower = region.strip().lower()
        countries = [c for c in countries if reg_lower in c["region"].lower()]
    summaries = [
        {
            "country_id": c["country_id"],
            "iso_alpha3": c["iso_alpha3"],
            "name": c["name"],
            "region": c["region"],
            "capital": c["capital"],
            "population_millions": c["population_millions"],
            "currency": c["currency"],
            "headline_fact": c["facts"][0],
        }
        for c in countries
    ]
    return {
        **_caller_context(),
        "count": len(summaries),
        "countries": summaries,
    }


@mcp.tool(
    description="Fetch detailed geographic, demographic, currency, language, timezone, and curated facts for a specific country by name or ISO code (e.g., japan, brazil, norway, kenya, canada, australia).",
    annotations=ToolAnnotations(
        title="Get Country Facts",
        readOnlyHint=True,
        destructiveHint=False,
        idempotentHint=True,
        openWorldHint=False,
    ),
)
def get_country_facts(country: str) -> dict[str, Any]:
    """Return full profile and curated facts for a country."""
    query = country.strip().lower().replace(" ", "_")
    match = COUNTRY_CATALOG.get(query)
    if not match:
        for entry in COUNTRY_CATALOG.values():
            if (
                query == entry["iso_alpha3"].lower()
                or query in entry["country_id"]
                or query.replace("_", " ") in entry["name"].lower()
                or query.replace("_", " ") == entry["capital"].lower()
            ):
                match = entry
                break
    if not match:
        return {
            **_caller_context(),
            "found": False,
            "available_countries": list(COUNTRY_CATALOG.keys()),
            "error": f"Country '{country}' was not found in the catalog.",
        }
    return {
        **_caller_context(),
        "found": True,
        "country": match,
    }


@mcp.tool(
    description="Return the verified Google OAuth 2.0 caller identity, Apigee X proxy mediation metadata, and hosting GCP project of the Country Facts MCP server.",
    annotations=ToolAnnotations(
        title="Get Country MCP & Apigee Caller Info",
        readOnlyHint=True,
        destructiveHint=False,
        idempotentHint=True,
        openWorldHint=False,
    ),
)
def get_authenticated_caller() -> dict[str, Any]:
    """Inspect the verified Google OAuth 2.0 caller context and Apigee X proxy headers."""
    return _caller_context()


_mcp_asgi_app = mcp.http_app(path="/mcp", stateless_http=True)
app = GoogleOAuth2Middleware(_mcp_asgi_app)
