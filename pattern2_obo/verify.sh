#!/usr/bin/env bash
# ==============================================================================
# End-to-End Verification Runner (Pattern 2: End-User Credential Passthrough):
# 1. Confirms public *.run.app access returns HTTP 404
# 2. Deploys & executes 6-step in-VPC Cloud Run Job (DNS + 15-hop PSC + Zero-SA
#    BigQuery 403 Proof + Apigee Anti-Spoofing 401 + Apigee Scope Gatekeeper 403 +
#    Cloud Run OIDC + OAuth2 client-ID pinning)
# 3. Prints Gemini Enterprise Web App URL, test prompt & BigQuery Audit Log command
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if [[ ! -t 1 ]]; then
  export CLOUDSDK_CORE_DISABLE_COLOR=1
fi

REBUILD_JOB=false
for arg in "$@"; do
  [[ "${arg}" == "--rebuild" ]] && REBUILD_JOB=true
done

ENV_FILE="${ENV_FILE:-.env}"
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} not found. Run ./deploy.sh first." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "${ENV_FILE}"

echo ""
echo "=== [1/3] Confirming Public Internet Exposure is Blocked (Expect HTTP 404) ==="
HTTP_PUB="$(curl -s -o /dev/null -w '%{http_code}' "${CLOUD_RUN_URL}/healthz")"
echo "Public ${CLOUD_RUN_URL}/healthz -> HTTP ${HTTP_PUB}"
if [[ "${HTTP_PUB}" != "404" ]]; then
  echo "ERROR: Expected HTTP 404 on public *.run.app URL, got ${HTTP_PUB}" >&2
  exit 1
fi

echo ""
echo "=== [2/3] Running In-VPC 6-Check PSC + Apigee Scope Gatekeeper + Zero-SA Verifier Job ==="
if [[ "${REBUILD_JOB}" != "true" ]] && gcloud run jobs describe mcp-bq-obo-vpc-verifier --region="${REGION}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  echo "[SKIP] Cloud Run Job 'mcp-bq-obo-vpc-verifier' already built; executing directly..."
  gcloud run jobs execute mcp-bq-obo-vpc-verifier \
    --region="${REGION}" \
    --project="${HUB_PROJECT_ID}" \
    --wait \
    --quiet
else
  cp certs/ca.crt verifier_job/ca.crt
  gcloud run jobs deploy mcp-bq-obo-vpc-verifier \
    --source=verifier_job \
    --region="${REGION}" \
    --project="${HUB_PROJECT_ID}" \
    --service-account="sa-mcp-verifier@${HUB_PROJECT_ID}.iam.gserviceaccount.com" \
    --network=vpc-mcp-internal \
    --subnet=subnet-ilb-backend \
    --vpc-egress=private-ranges-only \
    --max-retries=0 \
    --set-env-vars="BQ_MCP_HOST=${BQ_MCP_HOST},EXPECTED_HUB_ILB_IP=${HUB_APIGEE_ILB_IP},EXPECTED_APIGEE_PROJECT=${APIGEE_PROJECT_ID}" \
    --execute-now \
    --wait \
    --quiet
fi

LATEST_EXEC="$(gcloud run jobs executions list \
  --job=mcp-bq-obo-vpc-verifier \
  --region="${REGION}" \
  --project="${HUB_PROJECT_ID}" \
  --sort-by="~createTime" \
  --limit=1 \
  --format="value(name)" 2>/dev/null || true)"

echo ""
echo "=== Verifier Job Output (Cloud Logging${LATEST_EXEC:+: ${LATEST_EXEC}}) ==="
LOG_FILTER='resource.type="cloud_run_job" AND resource.labels.job_name="mcp-bq-obo-vpc-verifier"'
if [[ -n "${LATEST_EXEC}" ]]; then
  LOG_FILTER="${LOG_FILTER} AND labels.\"run.googleapis.com/execution_name\"=\"${LATEST_EXEC}\""
fi
for _ in 1 2 3 4; do
  LOG_OUT="$(gcloud logging read \
    "${LOG_FILTER}" \
    --project="${HUB_PROJECT_ID}" \
    --limit=60 \
    --order=asc \
    --format="value(textPayload)" 2>/dev/null || true)"
  if [[ -n "${LOG_OUT}" ]]; then
    echo "${LOG_OUT}"
    break
  fi
  sleep 3
done

echo ""
echo "=== [3/3] Gemini Enterprise Web App URL, OBO Test Prompt & Audit Log Check ==="
GE_WIDGET_ID="$(curl -s \
  "https://${GE_LOCATION}-discoveryengine.googleapis.com/v1/projects/${HUB_PROJECT_ID}/locations/${GE_LOCATION}/collections/default_collection/engines/${GE_APP_ID}/widgetConfigs/default_search_widget_config" \
  -H "Authorization: Bearer $(gcloud auth print-access-token 2>/dev/null)" \
  -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
  | jq -r '.configId')"

echo "1. Open Gemini Enterprise:"
echo "   https://vertexaisearch.cloud.google.com/home/cid/${GE_WIDGET_ID}"
echo "2. Click Connectors -> Authorize next to 'mcp-bq-obo-apigee-collection' to grant one-time 3LO consent (auth/bigquery)."
echo "3. Ask in chat:"
echo "   \"Query the top 5 baby names in California and New York since 2015 from BigQuery, and run the OBO credential evidence check to prove the query executed under my user email rather than the Cloud Run service account.\""
echo "4. Optional — verify principalEmail in Cloud Audit Logs (${APIGEE_PROJECT_ID}):"
echo "   gcloud logging read 'protoPayload.serviceName=\"bigquery.googleapis.com\" AND protoPayload.methodName=\"google.cloud.bigquery.v2.JobService.InsertJob\"' --project=${APIGEE_PROJECT_ID} --limit=5 --format='table(timestamp,protoPayload.authenticationInfo.principalEmail,protoPayload.resourceName)'"
echo ""
echo "=== [PASS] All automated private connectivity, Apigee scope gatekeeper & Zero-SA OBO checks passed ==="
