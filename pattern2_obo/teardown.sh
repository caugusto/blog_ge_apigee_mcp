#!/usr/bin/env bash
# ==============================================================================
# Clean Teardown Script (Pattern 2: End-User Credential Passthrough):
# By default, deletes the Apigee EVALUATION organization and deletes BOTH
# Google Cloud projects (${APIGEE_PROJECT_ID} and ${HUB_PROJECT_ID}) completely,
# then removes .env so a future ./deploy.sh run starts fresh.
#
# Pass `--keep-projects` if you prefer to delete only the provisioned resources
# inside the projects while keeping the project shells alive.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

ENV_FILE="${ENV_FILE:-.env}"
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} not found." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "${ENV_FILE}"

DELETE_PROJECTS=true
AUTO_YES=false
for arg in "$@"; do
  [[ "${arg}" == "--keep-projects" ]] && DELETE_PROJECTS=false
  [[ "${arg}" == "--delete-projects" ]] && DELETE_PROJECTS=true
  [[ "${arg}" == "--yes" || "${arg}" == "-y" ]] && AUTO_YES=true
done

echo "Target Hub Project:    ${HUB_PROJECT_ID}"
echo "Target Apigee Project: ${APIGEE_PROJECT_ID}"
echo "Delete Full Projects:  ${DELETE_PROJECTS} (default; pass --keep-projects to retain project shells)"

if [[ "${AUTO_YES}" != "true" ]]; then
  read -r -p "Proceed with teardown? [y/N]: " CONFIRM
  [[ "${CONFIRM}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

TOKEN="$(gcloud auth print-access-token 2>/dev/null)"

if [[ "${DELETE_PROJECTS}" == "true" ]]; then
  echo "[1/3] Releasing Apigee X EVALUATION organization '${APIGEE_PROJECT_ID}' (if provisioned)..."
  curl -s -X DELETE \
    "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}?retention=MINIMUM" \
    -H "Authorization: Bearer ${TOKEN}" >/dev/null 2>&1 || true

  echo "[2/3] Deleting project '${APIGEE_PROJECT_ID}'..."
  gcloud projects delete "${APIGEE_PROJECT_ID}" --quiet || true

  echo "[3/3] Deleting project '${HUB_PROJECT_ID}'..."
  gcloud projects delete "${HUB_PROJECT_ID}" --quiet || true

  rm -f "${ENV_FILE}"
  echo "Deleted projects ${APIGEE_PROJECT_ID} and ${HUB_PROJECT_ID}, and cleared ${ENV_FILE}."
  exit 0
fi

echo "[1/2] Disconnecting Gemini Enterprise MCP connector, removing Agent Registry entry, DNS record & Northbound ALB in ${HUB_PROJECT_ID}..."
if [[ -n "${GE_BQ_COLLECTION_ID:-}" ]]; then
  if [[ -n "${GE_APP_ID:-}" ]]; then
    ENG_URL="https://discoveryengine.googleapis.com/v1alpha/projects/${HUB_PROJECT_ID}/locations/${GE_LOCATION}/collections/default_collection/engines/${GE_APP_ID}"
    REMAINING_DS="$(curl -s "${ENG_URL}" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
      | jq -c --arg ds "${GE_BQ_COLLECTION_ID}_mcp_data" '[.dataStoreIds[]? | select(. != $ds)]' 2>/dev/null || echo '[]')"
    curl -s -X PATCH "${ENG_URL}?updateMask=dataStoreIds" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
      -H "Content-Type: application/json" \
      -d "{\"dataStoreIds\": ${REMAINING_DS}}" >/dev/null || true
  fi
  curl -s -X DELETE \
    "https://${GE_LOCATION}-discoveryengine.googleapis.com/v1alpha/projects/${HUB_PROJECT_ID}/locations/${GE_LOCATION}/collections/${GE_BQ_COLLECTION_ID}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" >/dev/null || true
fi

curl -s -X DELETE \
  "https://agentregistry.googleapis.com/v1/projects/${HUB_PROJECT_ID}/locations/${REGION}/services/mcp-bq-obo-poc" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" >/dev/null 2>&1 || true
gcloud run jobs delete mcp-bq-obo-vpc-verifier --region="${REGION}" --project="${HUB_PROJECT_ID}" --quiet || true
gcloud dns record-sets delete "${BQ_MCP_HOST}." --type=A --zone=zone-corp-internal --project="${HUB_PROJECT_ID}" --quiet || true
gcloud compute forwarding-rules delete fr-apigee-bq-obo --region="${REGION}" --project="${HUB_PROJECT_ID}" --quiet || true
gcloud compute target-https-proxies delete tp-apigee-bq-obo --region="${REGION}" --project="${HUB_PROJECT_ID}" --quiet || true
gcloud compute url-maps delete um-apigee-bq-obo --region="${REGION}" --project="${HUB_PROJECT_ID}" --quiet || true
gcloud compute backend-services delete bs-apigee-bq-obo --region="${REGION}" --project="${HUB_PROJECT_ID}" --quiet || true
gcloud compute network-endpoint-groups delete neg-psc-apigee-bq-obo --region="${REGION}" --project="${HUB_PROJECT_ID}" --quiet || true
gcloud compute ssl-certificates delete cert-mcp-bq-hub --region="${REGION}" --project="${HUB_PROJECT_ID}" --quiet || true
gcloud compute addresses delete ip-ilb-apigee-bq-obo --region="${REGION}" --project="${HUB_PROJECT_ID}" --quiet || true

echo "[2/2] Removing Apigee X EndpointAttachment, Runtime Instance, Southbound PSC/ALB & Cloud Run in ${APIGEE_PROJECT_ID}..."
curl -s -X DELETE \
  "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/endpointAttachments/ea-mcp-bq-obo" \
  -H "Authorization: Bearer $(gcloud auth print-access-token 2>/dev/null)" >/dev/null || true

curl -s -X DELETE \
  "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/instances/apigee-${REGION}" \
  -H "Authorization: Bearer $(gcloud auth print-access-token 2>/dev/null)" >/dev/null || true

gcloud compute service-attachments delete sa-psc-mcp-bq-obo --region="${REGION}" --project="${APIGEE_PROJECT_ID}" --quiet || true
gcloud compute forwarding-rules delete fr-mcp-bq-obo-poc --region="${REGION}" --project="${APIGEE_PROJECT_ID}" --quiet || true
gcloud compute target-https-proxies delete tp-mcp-bq-obo-poc --region="${REGION}" --project="${APIGEE_PROJECT_ID}" --quiet || true
gcloud compute url-maps delete um-mcp-bq-obo-poc --region="${REGION}" --project="${APIGEE_PROJECT_ID}" --quiet || true
gcloud compute backend-services delete bs-mcp-bq-obo-poc --region="${REGION}" --project="${APIGEE_PROJECT_ID}" --quiet || true
gcloud compute network-endpoint-groups delete neg-mcp-bq-obo-poc --region="${REGION}" --project="${APIGEE_PROJECT_ID}" --quiet || true
gcloud run services delete mcp-bq-obo-poc --region="${REGION}" --project="${APIGEE_PROJECT_ID}" --quiet || true

echo "Teardown complete (projects kept)."
