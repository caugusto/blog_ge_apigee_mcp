#!/usr/bin/env bash
# ==============================================================================
# Clean Teardown Script:
# Removes evaluation ALBs, PSC attachments, Apigee X runtime instance, and
# Cloud Run service to stop ongoing forwarding-rule charges.
# Pass `--delete-projects` to delete both Google Cloud projects completely.
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

DELETE_PROJECTS=false
AUTO_YES=false
for arg in "$@"; do
  [[ "${arg}" == "--delete-projects" ]] && DELETE_PROJECTS=true
  [[ "${arg}" == "--yes" || "${arg}" == "-y" ]] && AUTO_YES=true
done

echo "Target Hub Project:    ${HUB_PROJECT_ID}"
echo "Target Apigee Project: ${APIGEE_PROJECT_ID}"
echo "Delete Full Projects:  ${DELETE_PROJECTS}"

if [[ "${AUTO_YES}" != "true" ]]; then
  read -r -p "Proceed with teardown? [y/N]: " CONFIRM
  [[ "${CONFIRM}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

if [[ "${DELETE_PROJECTS}" == "true" ]]; then
  gcloud projects delete "${APIGEE_PROJECT_ID}" --quiet
  gcloud projects delete "${HUB_PROJECT_ID}" --quiet
  echo "Deleted projects ${APIGEE_PROJECT_ID} and ${HUB_PROJECT_ID}."
  exit 0
fi

TOKEN="$(gcloud auth print-access-token)"

echo "[1/2] Removing connector, Agent Registry entry, DNS record & Northbound ALB in ${HUB_PROJECT_ID}..."
if [[ -n "${GE_COUNTRIES_COLLECTION_ID:-}" ]]; then
  curl -s -X DELETE \
    "https://${GE_LOCATION}-discoveryengine.googleapis.com/v1alpha/projects/${HUB_PROJECT_ID}/locations/${GE_LOCATION}/collections/${GE_COUNTRIES_COLLECTION_ID}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" >/dev/null || true
fi

gcloud agent-registry services delete mcp-countries-poc --location="${REGION}" --project="${HUB_PROJECT_ID}" --quiet || true
gcloud run jobs delete mcp-countries-vpc-verifier --region="${REGION}" --project="${HUB_PROJECT_ID}" --quiet || true
gcloud dns record-sets delete "${COUNTRIES_HOST}." --type=A --zone=zone-corp-internal --project="${HUB_PROJECT_ID}" --quiet || true
gcloud compute forwarding-rules delete fr-apigee-countries --region="${REGION}" --project="${HUB_PROJECT_ID}" --quiet || true
gcloud compute target-https-proxies delete tp-apigee-countries --region="${REGION}" --project="${HUB_PROJECT_ID}" --quiet || true
gcloud compute url-maps delete um-apigee-countries --region="${REGION}" --project="${HUB_PROJECT_ID}" --quiet || true
gcloud compute backend-services delete bs-apigee-countries --region="${REGION}" --project="${HUB_PROJECT_ID}" --quiet || true
gcloud compute network-endpoint-groups delete neg-psc-apigee-countries --region="${REGION}" --project="${HUB_PROJECT_ID}" --quiet || true
gcloud compute ssl-certificates delete cert-mcp-countries-hub --region="${REGION}" --project="${HUB_PROJECT_ID}" --quiet || true
gcloud compute addresses delete ip-ilb-apigee-countries --region="${REGION}" --project="${HUB_PROJECT_ID}" --quiet || true

echo "[2/2] Removing Apigee X EndpointAttachment, Runtime Instance, Southbound PSC/ALB & Cloud Run in ${APIGEE_PROJECT_ID}..."
curl -s -X DELETE \
  "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/endpointAttachments/ea-mcp-countries" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" >/dev/null || true

curl -s -X DELETE \
  "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/instances/apigee-${REGION}" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" >/dev/null || true

gcloud compute service-attachments delete sa-psc-mcp-countries --region="${REGION}" --project="${APIGEE_PROJECT_ID}" --quiet || true
gcloud compute forwarding-rules delete fr-mcp-countries-poc --region="${REGION}" --project="${APIGEE_PROJECT_ID}" --quiet || true
gcloud compute target-https-proxies delete tp-mcp-countries-poc --region="${REGION}" --project="${APIGEE_PROJECT_ID}" --quiet || true
gcloud compute url-maps delete um-mcp-countries-poc --region="${REGION}" --project="${APIGEE_PROJECT_ID}" --quiet || true
gcloud compute backend-services delete bs-mcp-countries-poc --region="${REGION}" --project="${APIGEE_PROJECT_ID}" --quiet || true
gcloud compute network-endpoint-groups delete neg-mcp-countries-poc --region="${REGION}" --project="${APIGEE_PROJECT_ID}" --quiet || true
gcloud run services delete mcp-countries-poc --region="${REGION}" --project="${APIGEE_PROJECT_ID}" --quiet || true

echo "Teardown complete."
