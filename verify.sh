#!/usr/bin/env bash
# ==============================================================================
# End-to-End Verification Runner:
# 1. Confirms public *.run.app access returns HTTP 404
# 2. Deploys & executes in-VPC Cloud Run Job (DNS + Northbound PSC + Apigee X +
#    Southbound PSC + Cloud Run OIDC + OAuth2 client-ID pinning)
# 3. Prints the Gemini Enterprise Web App URL & test prompts
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
echo "=== [2/3] Running In-VPC Northbound & Southbound PSC + Apigee X Verifier Job ==="
if [[ "${REBUILD_JOB}" != "true" ]] && gcloud run jobs describe mcp-countries-vpc-verifier --region="${REGION}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  echo "[SKIP] Cloud Run Job 'mcp-countries-vpc-verifier' already built; executing directly..."
  gcloud run jobs execute mcp-countries-vpc-verifier \
    --region="${REGION}" \
    --project="${HUB_PROJECT_ID}" \
    --wait \
    --quiet
else
  cp certs/ca.crt verifier_job/ca.crt
  gcloud run jobs deploy mcp-countries-vpc-verifier \
    --source=verifier_job \
    --region="${REGION}" \
    --project="${HUB_PROJECT_ID}" \
    --service-account="sa-mcp-verifier@${HUB_PROJECT_ID}.iam.gserviceaccount.com" \
    --network=vpc-mcp-internal \
    --subnet=subnet-ilb-backend \
    --vpc-egress=private-ranges-only \
    --max-retries=0 \
    --set-env-vars="COUNTRIES_HOST=${COUNTRIES_HOST},EXPECTED_HUB_ILB_IP=${HUB_APIGEE_ILB_IP},EXPECTED_APIGEE_PROJECT=${APIGEE_PROJECT_ID}" \
    --execute-now \
    --wait \
    --quiet
fi

echo ""
echo "=== Verifier Job Output (Cloud Logging) ==="
gcloud logging read \
  'resource.type="cloud_run_job" AND resource.labels.job_name="mcp-countries-vpc-verifier"' \
  --project="${HUB_PROJECT_ID}" \
  --limit=25 \
  --order=asc \
  --format="value(textPayload)"

echo ""
echo "=== [3/3] Gemini Enterprise Web App URL & Sample Prompts ==="
GE_WIDGET_ID="$(curl -s \
  "https://${GE_LOCATION}-discoveryengine.googleapis.com/v1/projects/${HUB_PROJECT_ID}/locations/${GE_LOCATION}/collections/default_collection/engines/${GE_APP_ID}/widgetConfigs/default_search_widget_config" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
  | jq -r '.configId')"

echo "1. Open Gemini Enterprise:"
echo "   https://vertexaisearch.cloud.google.com/home/cid/${GE_WIDGET_ID}"
echo "2. Click Connectors -> Authorize next to 'mcp-countries-apigee-collection' to complete one-time 3LO OAuth consent."
echo "3. Ask in chat:"
echo "   \"Get country facts for Japan and Norway, and report which Google Cloud project and Apigee X proxy mediated the call along with my authenticated email.\""
