#!/usr/bin/env bash
# ==============================================================================
# Automated End-to-End Provisioner:
# Internal Cloud Run MCP Behind Apigee X + Dual PSC + Agent Gateway + Gemini Enterprise
#
# Starts from blank Google Cloud projects (or reuses existing ones idempotently).
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

ENV_FILE="${ENV_FILE:-.env}"

# ------------------------------------------------------------------------------
# Pretty logging helpers
# ------------------------------------------------------------------------------
BLUE="\033[1;34m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
NC="\033[0m"

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
stage() { echo -e "\n${BLUE}==============================================================================${NC}\n${BLUE} $*${NC}\n${BLUE}==============================================================================${NC}"; }

get_token() {
  gcloud auth print-access-token 2>/dev/null
}

save_env() {
  cat > "${ENV_FILE}" <<EOF
BILLING_ACCOUNT_ID="${BILLING_ACCOUNT_ID}"
HUB_PROJECT_ID="${HUB_PROJECT_ID}"
APIGEE_PROJECT_ID="${APIGEE_PROJECT_ID}"
REGION="${REGION}"
GE_LOCATION="${GE_LOCATION}"
GE_APP_ID="${GE_APP_ID}"
COMPANY_NAME="${COMPANY_NAME}"
OAUTH_CLIENT_ID="${OAUTH_CLIENT_ID}"
OAUTH_CLIENT_SECRET="${OAUTH_CLIENT_SECRET}"
COUNTRIES_HOST="${COUNTRIES_HOST}"
HUB_APIGEE_ILB_IP="${HUB_APIGEE_ILB_IP}"
SB_ILB_IP="${SB_ILB_IP}"
CLOUD_RUN_URL="${CLOUD_RUN_URL:-}"
EA_HOST="${EA_HOST:-}"
APIGEE_NB_SERVICE_ATTACHMENT="${APIGEE_NB_SERVICE_ATTACHMENT:-}"
MCP_COUNTRIES_REGISTRY_URI="${MCP_COUNTRIES_REGISTRY_URI:-}"
GE_COUNTRIES_COLLECTION_ID="${GE_COUNTRIES_COLLECTION_ID:-}"
EOF
  chmod 600 "${ENV_FILE}"
}

# ------------------------------------------------------------------------------
# Stage 0: Preflight & Interactive Configuration Wizard
# ------------------------------------------------------------------------------
stage "Stage 0: Preflight Checks & Interactive Setup"

for cmd in gcloud curl jq openssl zip python3 sed; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    err "Required CLI '${cmd}' is not installed. Install it and re-run ./deploy.sh."
    exit 1
  fi
done

if ! gcloud auth print-access-token >/dev/null 2>&1; then
  warn "No active gcloud session detected. Launching 'gcloud auth login'..."
  gcloud auth login
fi

if [[ -f "${ENV_FILE}" ]]; then
  info "Loading saved configuration from ${ENV_FILE}..."
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  if [[ -n "${HUB_PROJECT_ID:-}" ]] && [[ "$(gcloud projects describe "${HUB_PROJECT_ID}" --format='value(lifecycleState)' 2>/dev/null || echo 'MISSING')" == "DELETE_REQUESTED" ]]; then
    warn "Saved Hub project '${HUB_PROJECT_ID}' is pending deletion; clearing stale project IDs from ${ENV_FILE}."
    HUB_PROJECT_ID=""
    APIGEE_PROJECT_ID=""
    CLOUD_RUN_URL=""
    EA_HOST=""
    APIGEE_NB_SERVICE_ATTACHMENT=""
    MCP_COUNTRIES_REGISTRY_URI=""
    GE_COUNTRIES_COLLECTION_ID=""
  fi
fi

RAND_SUFFIX="$(date +%s | tail -c 5)"
DEFAULT_BILLING="$(gcloud billing accounts list --filter='open=true' --format='value(name)' 2>/dev/null | head -n 1 | sed 's|billingAccounts/||')"

echo ""
info "Press Enter to accept [default] values, or type a custom value:"
echo ""

if [[ -z "${BILLING_ACCOUNT_ID:-}" ]]; then
  if [[ -n "${DEFAULT_BILLING}" ]]; then
    info "Detected open billing accounts:"
    gcloud billing accounts list --filter="open=true" --format="table(name.basename(),displayName,open)" || true
  fi
  read -r -p "1. Google Cloud Billing Account ID [${DEFAULT_BILLING}]: " INPUT_BILLING
  BILLING_ACCOUNT_ID="${INPUT_BILLING:-${DEFAULT_BILLING}}"
fi
if [[ -z "${BILLING_ACCOUNT_ID}" ]]; then
  err "BILLING_ACCOUNT_ID is required."
  exit 1
fi

DEF_HUB="${HUB_PROJECT_ID:-ge-mcp-hub-${RAND_SUFFIX}}"
read -r -p "2. Hub AI & Governance Project ID [${DEF_HUB}]: " INPUT_HUB
HUB_PROJECT_ID="${INPUT_HUB:-${DEF_HUB}}"

DEF_APIGEE="${APIGEE_PROJECT_ID:-apigee-mcp-${RAND_SUFFIX}}"
read -r -p "3. Dedicated Apigee X & MCP Project ID [${DEF_APIGEE}]: " INPUT_APIGEE
APIGEE_PROJECT_ID="${INPUT_APIGEE:-${DEF_APIGEE}}"

DEF_REGION="${REGION:-us-central1}"
read -r -p "4. Google Cloud Region [${DEF_REGION}]: " INPUT_REGION
REGION="${INPUT_REGION:-${DEF_REGION}}"

DEF_APP="${GE_APP_ID:-ge-apigee-mcp-app}"
read -r -p "5. Gemini Enterprise App ID [${DEF_APP}]: " INPUT_APP
GE_APP_ID="${INPUT_APP:-${DEF_APP}}"

DEF_COMPANY="${COMPANY_NAME:-Enterprise AI}"
read -r -p "6. Company Display Name for Gemini Enterprise [${DEF_COMPANY}]: " INPUT_COMPANY
COMPANY_NAME="${INPUT_COMPANY:-${DEF_COMPANY}}"

GE_LOCATION="${GE_LOCATION:-global}"
COUNTRIES_HOST="${COUNTRIES_HOST:-mcp-countries.corp.internal}"
COUNTRIES_MCP_URL="https://${COUNTRIES_HOST}/mcp"
HUB_APIGEE_ILB_IP="${HUB_APIGEE_ILB_IP:-10.10.1.30}"
SB_ILB_IP="${SB_ILB_IP:-10.30.1.10}"
OAUTH_CLIENT_ID="${OAUTH_CLIENT_ID:-}"
OAUTH_CLIENT_SECRET="${OAUTH_CLIENT_SECRET:-}"

mkdir -p certs cfg
save_env
ok "Saved configuration to ${ENV_FILE}"

# ------------------------------------------------------------------------------
# Stage 1: Create Projects, Link Billing, Enable APIs & Configure IAM
# ------------------------------------------------------------------------------
stage "Stage 1: Projects, Billing, APIs & Service Accounts"

for PROJ in "${HUB_PROJECT_ID}" "${APIGEE_PROJECT_ID}"; do
  P_STATE="$(gcloud projects describe "${PROJ}" --format='value(lifecycleState)' 2>/dev/null || echo 'MISSING')"
  if [[ "${P_STATE}" == "ACTIVE" ]]; then
    ok "Project '${PROJ}' already exists and is ACTIVE."
  elif [[ "${P_STATE}" == "DELETE_REQUESTED" ]]; then
    err "Project '${PROJ}' is in DELETE_REQUESTED state. Run 'gcloud projects undelete ${PROJ}' or re-run ./deploy.sh with a new project ID."
    exit 1
  else
    info "Creating project '${PROJ}'..."
    gcloud projects create "${PROJ}"
    ok "Created project '${PROJ}'."
  fi
  info "Linking billing account '${BILLING_ACCOUNT_ID}' to '${PROJ}'..."
  gcloud billing projects link "${PROJ}" --billing-account="${BILLING_ACCOUNT_ID}" >/dev/null
done

HUB_PROJECT_NUMBER="$(gcloud projects describe "${HUB_PROJECT_ID}" --format='value(projectNumber)')"
APIGEE_PROJECT_NUMBER="$(gcloud projects describe "${APIGEE_PROJECT_ID}" --format='value(projectNumber)')"
ORG_ID="$(gcloud projects get-ancestors "${HUB_PROJECT_ID}" --format=json | jq -r '[.[] | select(.type=="organization") | .id][0] // empty')"

if [[ -n "${ORG_ID}" ]]; then
  TRUST_DOMAIN="agents.global.org-${ORG_ID}.system.id.goog"
else
  TRUST_DOMAIN="agents.global.proj-${HUB_PROJECT_NUMBER}.system.id.goog"
fi

info "Enabling Google Cloud APIs on Hub project (${HUB_PROJECT_ID})..."
HUB_APIS=(
  serviceusage.googleapis.com
  cloudresourcemanager.googleapis.com
  discoveryengine.googleapis.com
  networkservices.googleapis.com
  networksecurity.googleapis.com
  serviceextensions.googleapis.com
  iap.googleapis.com
  agentregistry.googleapis.com
  agentidentity.googleapis.com
  agentidentitycredentials.googleapis.com
  aiplatform.googleapis.com
  compute.googleapis.com
  dns.googleapis.com
  certificatemanager.googleapis.com
  run.googleapis.com
  cloudbuild.googleapis.com
  artifactregistry.googleapis.com
  storage.googleapis.com
  orgpolicy.googleapis.com
  iam.googleapis.com
  iamcredentials.googleapis.com
  logging.googleapis.com
)
if ! gcloud services enable "${HUB_APIS[@]}" --project="${HUB_PROJECT_ID}"; then
  warn "Batch API enablement had a warning; enabling Hub APIs individually..."
  for api in "${HUB_APIS[@]}"; do
    gcloud services enable "${api}" --project="${HUB_PROJECT_ID}" 2>/dev/null || warn "Optional/preview API '${api}' skipped."
  done
fi

if [[ -n "${ORG_ID}" ]]; then
  info "Ensuring custom MCP connectors and IAM v3 UAP bindings are allowed on ${HUB_PROJECT_ID}..."
  for CONSTRAINT in \
    discoveryengine.managed.disableCustomMcpServerConnector \
    iam.managed.disableAccessPolicyBinding; do
    cat > "cfg/policy_${CONSTRAINT}.yaml" <<EOF
name: projects/${HUB_PROJECT_NUMBER}/policies/${CONSTRAINT}
spec:
  rules:
  - enforce: false
EOF
    gcloud org-policies set-policy "cfg/policy_${CONSTRAINT}.yaml" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1 || \
      warn "Could not override ${CONSTRAINT} (may already be allowed or require Org Policy Admin)."
  done
fi

info "Enabling Google Cloud APIs on Apigee & MCP project (${APIGEE_PROJECT_ID})..."
APIGEE_APIS=(
  serviceusage.googleapis.com
  cloudresourcemanager.googleapis.com
  apigee.googleapis.com
  compute.googleapis.com
  run.googleapis.com
  cloudkms.googleapis.com
  cloudbuild.googleapis.com
  artifactregistry.googleapis.com
  storage.googleapis.com
  iam.googleapis.com
  iamcredentials.googleapis.com
  logging.googleapis.com
)
gcloud services enable "${APIGEE_APIS[@]}" --project="${APIGEE_PROJECT_ID}"

for SVC in apigee.googleapis.com cloudkms.googleapis.com compute.googleapis.com cloudbuild.googleapis.com; do
  gcloud beta services identity create --service="${SVC}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1 || true
done
for SVC in networkservices.googleapis.com discoveryengine.googleapis.com compute.googleapis.com cloudbuild.googleapis.com; do
  gcloud beta services identity create --service="${SVC}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1 || true
done

# Grant Cloud Build source-deploy permissions to Default Compute SAs (required when iam.automaticIamGrantsForDefaultServiceAccounts is enforced)
for PAIR in "${HUB_PROJECT_ID}:${HUB_PROJECT_NUMBER}" "${APIGEE_PROJECT_ID}:${APIGEE_PROJECT_NUMBER}"; do
  IFS=":" read -r P_ID P_NUM <<< "${PAIR}"
  for BUILD_ROLE in roles/storage.admin roles/artifactregistry.writer roles/logging.logWriter roles/cloudbuild.builds.builder; do
    gcloud projects add-iam-policy-binding "${P_ID}" \
      --member="serviceAccount:${P_NUM}-compute@developer.gserviceaccount.com" \
      --role="${BUILD_ROLE}" --condition=None --quiet >/dev/null 2>&1 || true
  done
done

APIGEE_SERVICE_AGENT="service-${APIGEE_PROJECT_NUMBER}@gcp-sa-apigee.iam.gserviceaccount.com"

for SA_SPEC in \
  "${APIGEE_PROJECT_ID}:sa-mcp-countries:Country Facts Internal MCP Runtime SA" \
  "${APIGEE_PROJECT_ID}:sa-apigee-invoker:Apigee X Southbound Cloud Run Invoker SA" \
  "${HUB_PROJECT_ID}:sa-mcp-verifier:In-VPC MCP Verifier SA"; do
  IFS=":" read -r P_ID SA_NAME SA_DESC <<< "${SA_SPEC}"
  if ! gcloud iam service-accounts describe "${SA_NAME}@${P_ID}.iam.gserviceaccount.com" --project="${P_ID}" >/dev/null 2>&1; then
    gcloud iam service-accounts create "${SA_NAME}" --display-name="${SA_DESC}" --project="${P_ID}"
  fi
done

for ROLE in roles/iam.serviceAccountUser roles/iam.serviceAccountTokenCreator; do
  gcloud iam service-accounts add-iam-policy-binding \
    "sa-apigee-invoker@${APIGEE_PROJECT_ID}.iam.gserviceaccount.com" \
    --member="serviceAccount:${APIGEE_SERVICE_AGENT}" \
    --role="${ROLE}" \
    --project="${APIGEE_PROJECT_ID}" >/dev/null
done

# ------------------------------------------------------------------------------
# Stage 2: Guided Web OAuth 2.0 Client Collection (Browser-Only Security Control)
# ------------------------------------------------------------------------------
stage "Stage 2: Google Auth Platform Web OAuth 2.0 Client"

if [[ -z "${OAUTH_CLIENT_ID}" || -z "${OAUTH_CLIENT_SECRET}" ]]; then
  echo -e "${YELLOW}Google Cloud restricts 3LO Web OAuth 2.0 client creation (*.apps.googleusercontent.com)"
  echo -e "to the Google Cloud Console for anti-phishing security (60-second one-time step):${NC}"
  echo ""
  echo "  1. Open Google Auth Platform for ${HUB_PROJECT_ID}:"
  echo "     https://console.cloud.google.com/auth/clients/create?project=${HUB_PROJECT_ID}"
  echo "     (If prompted to configure the consent screen first, click Get Started -> Internal -> Create)"
  echo "  2. Select Application type: Web application"
  echo "  3. Under Authorized redirect URIs, click + Add URI and paste:"
  echo "     https://vertexaisearch.cloud.google.com/oauth-redirect"
  echo "  4. Click Create and paste the Client ID and Client Secret below."
  echo ""
  while [[ -z "${OAUTH_CLIENT_ID}" ]]; do
    read -r -p "Paste OAuth 2.0 Client ID (*.apps.googleusercontent.com): " OAUTH_CLIENT_ID
  done
  while [[ -z "${OAUTH_CLIENT_SECRET}" ]]; do
    read -r -s -p "Paste OAuth 2.0 Client Secret (input hidden): " OAUTH_CLIENT_SECRET
    echo ""
  done
  save_env
  ok "OAuth 2.0 client credentials saved to ${ENV_FILE}. Remaining deployment runs 100% unattended."
else
  ok "Using OAuth 2.0 Client ID from ${ENV_FILE}: ${OAUTH_CLIENT_ID}"
fi

# ------------------------------------------------------------------------------
# Stage 3: Automated Gemini Enterprise Free Trial License & App Provisioning
# ------------------------------------------------------------------------------
stage "Stage 3: Gemini Enterprise Trial License & App (${GE_APP_ID})"

ACTIVE_LICENSES="$(curl -s \
  -H "Authorization: Bearer $(get_token)" \
  -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
  "https://${GE_LOCATION}-discoveryengine.googleapis.com/v1alpha/projects/${HUB_PROJECT_ID}/locations/${GE_LOCATION}/licenseConfigs" \
  | jq -r '[.licenseConfigs[]? | select(.state == "ACTIVE")] | length')"

if [[ "${ACTIVE_LICENSES}" == "0" ]]; then
  info "No active Gemini Enterprise license found on ${HUB_PROJECT_ID}; provisioning 30-day free trial license..."
  YEAR="$(date -u +%Y)"
  MONTH="$(date -u +%-m)"
  DAY="$(date -u +%-d)"

  TRIAL_RESP="$(curl -s -X POST \
    "https://${GE_LOCATION}-discoveryengine.googleapis.com/v1alpha/projects/${HUB_PROJECT_ID}/locations/${GE_LOCATION}/licenseConfigs?licenseConfigId=free_trial_gemini" \
    -H "Authorization: Bearer $(get_token)" \
    -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
    -H "Content-Type: application/json" \
    -d "{
      \"licenseCount\": \"50\",
      \"subscriptionTier\": \"SUBSCRIPTION_TIER_SEARCH_AND_ASSISTANT\",
      \"startDate\": {\"year\": ${YEAR}, \"month\": ${MONTH}, \"day\": ${DAY}},
      \"subscriptionTerm\": \"SUBSCRIPTION_TERM_ONE_MONTH\",
      \"freeTrial\": true,
      \"geminiBundle\": true
    }")"

  if echo "${TRIAL_RESP}" | jq -e '.name' >/dev/null 2>&1; then
    LIC_NAME="$(echo "${TRIAL_RESP}" | jq -r '.name')"
    ok "Activated Gemini Enterprise 30-day free trial (${LIC_NAME})."
    curl -s -X PATCH \
      "https://${GE_LOCATION}-discoveryengine.googleapis.com/v1alpha/projects/${HUB_PROJECT_ID}/locations/${GE_LOCATION}/userStores/default_user_store?updateMask=defaultLicenseConfig,enableLicenseAutoRegister" \
      -H "Authorization: Bearer $(get_token)" \
      -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
      -H "Content-Type: application/json" \
      -d "{
        \"defaultLicenseConfig\": \"${LIC_NAME}\",
        \"enableLicenseAutoRegister\": true
      }" >/dev/null || true
  else
    warn "Free trial API response: $(echo "${TRIAL_RESP}" | tr -d '\n' | cut -c1-220)"
    warn "Continuing (billing account may already hold an org-level Gemini Enterprise entitlement)."
  fi
else
  ok "Found ${ACTIVE_LICENSES} active Gemini Enterprise license config(s) on ${HUB_PROJECT_ID}."
fi

# Ensure initial DataStore exists so CreateEngineRequest succeeds on blank projects
DS_URL="https://${GE_LOCATION}-discoveryengine.googleapis.com/v1alpha/projects/${HUB_PROJECT_NUMBER}/locations/${GE_LOCATION}/collections/default_collection/dataStores/ge-init-store"
if [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(get_token)" -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" "${DS_URL}")" != "200" ]]; then
  info "Creating initial Discovery Engine DataStore 'ge-init-store'..."
  curl -s -X POST \
    "https://${GE_LOCATION}-discoveryengine.googleapis.com/v1alpha/projects/${HUB_PROJECT_NUMBER}/locations/${GE_LOCATION}/collections/default_collection/dataStores?dataStoreId=ge-init-store" \
    -H "Authorization: Bearer $(get_token)" \
    -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
    -H "Content-Type: application/json" \
    -d '{
      "displayName": "Gemini Enterprise Initial Store",
      "industryVertical": "GENERIC",
      "solutionTypes": ["SOLUTION_TYPE_SEARCH"],
      "contentConfig": "CONTENT_REQUIRED"
    }' >/dev/null

  for _ in {1..30}; do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(get_token)" -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" "${DS_URL}")" == "200" ]] && break
    sleep 4
  done
fi

ENG_URL="https://${GE_LOCATION}-discoveryengine.googleapis.com/v1alpha/projects/${HUB_PROJECT_NUMBER}/locations/${GE_LOCATION}/collections/default_collection/engines/${GE_APP_ID}"
if [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(get_token)" -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" "${ENG_URL}")" != "200" ]]; then
  info "Creating Gemini Enterprise app '${GE_APP_ID}'..."
  ENG_CREATE="$(curl -s -X POST \
    "https://${GE_LOCATION}-discoveryengine.googleapis.com/v1alpha/projects/${HUB_PROJECT_NUMBER}/locations/${GE_LOCATION}/collections/default_collection/engines?engineId=${GE_APP_ID}" \
    -H "Authorization: Bearer $(get_token)" \
    -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
    -H "Content-Type: application/json" \
    -d "{
      \"displayName\": \"${GE_APP_ID}\",
      \"solutionType\": \"SOLUTION_TYPE_SEARCH\",
      \"industryVertical\": \"GENERIC\",
      \"appType\": \"APP_TYPE_INTRANET\",
      \"searchEngineConfig\": {
        \"searchTier\": \"SEARCH_TIER_ENTERPRISE\",
        \"searchAddOns\": [\"SEARCH_ADD_ON_LLM\"]
      },
      \"commonConfig\": {\"companyName\": \"${COMPANY_NAME}\"},
      \"dataStoreIds\": [\"ge-init-store\"]
    }")"

  if echo "${ENG_CREATE}" | jq -e '.error' >/dev/null 2>&1; then
    err "Failed creating Gemini Enterprise app: ${ENG_CREATE}"
    err "Enable a subscription in Console -> Gemini Enterprise -> Subscriptions (${HUB_PROJECT_ID}) and re-run ./deploy.sh."
    exit 1
  fi

  for _ in {1..40}; do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(get_token)" -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" "${ENG_URL}")" == "200" ]] && break
    sleep 5
  done
  ok "Gemini Enterprise app '${GE_APP_ID}' ready."
else
  ok "Gemini Enterprise app '${GE_APP_ID}' already exists."
fi

# ------------------------------------------------------------------------------
# Stage 4: Hub PKI, Hub VPC, Private DNS & Agent Gateway
# ------------------------------------------------------------------------------
stage "Stage 4: Hub Private PKI, VPC, Cloud DNS & Agent Gateway"

if [[ ! -f certs/ca.crt || ! -f certs/ca.key ]]; then
  info "Generating Enterprise Private Root CA (certs/ca.crt)..."
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout certs/ca.key -out certs/ca.crt \
    -subj "/O=Enterprise Internal PKI/CN=MCP Internal Root CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"
fi

if ! gcloud certificate-manager trust-configs describe tc-mcp-corp-internal --location="${REGION}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud certificate-manager trust-configs create tc-mcp-corp-internal \
    --location="${REGION}" \
    --trust-store="trust-anchors=certs/ca.crt" \
    --project="${HUB_PROJECT_ID}"
fi

if ! gcloud compute networks describe vpc-mcp-internal --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute networks create vpc-mcp-internal --subnet-mode=custom --project="${HUB_PROJECT_ID}"
fi

if ! gcloud compute networks subnets describe subnet-ilb-backend --region="${REGION}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute networks subnets create subnet-ilb-backend \
    --network=vpc-mcp-internal --region="${REGION}" --range=10.10.1.0/24 \
    --enable-private-ip-google-access --project="${HUB_PROJECT_ID}"
fi

if ! gcloud compute networks subnets describe subnet-ilb-proxy --region="${REGION}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute networks subnets create subnet-ilb-proxy \
    --network=vpc-mcp-internal --region="${REGION}" --range=10.10.2.0/24 \
    --purpose=REGIONAL_MANAGED_PROXY --role=ACTIVE --project="${HUB_PROJECT_ID}"
fi

if ! gcloud compute networks subnets describe subnet-agw-psc --region="${REGION}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute networks subnets create subnet-agw-psc \
    --network=vpc-mcp-internal --region="${REGION}" --range=10.10.3.0/28 \
    --enable-private-ip-google-access --project="${HUB_PROJECT_ID}"
fi

if ! gcloud compute network-attachments describe na-agw-mcp-internal --region="${REGION}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute network-attachments create na-agw-mcp-internal \
    --region="${REGION}" --subnets=subnet-agw-psc \
    --connection-preference=ACCEPT_AUTOMATIC --project="${HUB_PROJECT_ID}"
fi

if ! gcloud dns managed-zones describe zone-corp-internal --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud dns managed-zones create zone-corp-internal \
    --dns-name="corp.internal." --description="Private DNS zone for internal MCP services" \
    --visibility=private --networks=vpc-mcp-internal --project="${HUB_PROJECT_ID}"
fi

AGW_SA="service-${HUB_PROJECT_NUMBER}@gcp-sa-agentgateway.iam.gserviceaccount.com"
if ! gcloud projects add-iam-policy-binding "${HUB_PROJECT_ID}" \
  --member="serviceAccount:${AGW_SA}" \
  --role="roles/agentgateway.serviceAgent" --condition=None --quiet >/dev/null 2>&1; then
  info "Initializing Agent Gateway service agent (${AGW_SA}) on blank project..."
  BOOT_OP="$(curl -s -X POST \
    "https://networkservices.googleapis.com/v1/projects/${HUB_PROJECT_ID}/locations/${REGION}/agentGateways?agentGatewayId=agw-sa-init" \
    -H "Authorization: Bearer $(get_token)" \
    -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
    -H "Content-Type: application/json" \
    -d '{"protocols":["MCP"],"googleManaged":{"governedAccessPath":"AGENT_TO_ANYWHERE"}}' | jq -r '.name // empty')"
  if [[ -n "${BOOT_OP}" ]]; then
    for _ in {1..30}; do
      [[ "$(curl -s -H "Authorization: Bearer $(get_token)" -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" "https://networkservices.googleapis.com/v1/${BOOT_OP}" | jq -r '.done // false')" == "true" ]] && break
      sleep 5
    done
    DEL_BOOT="$(curl -s -X DELETE \
      "https://networkservices.googleapis.com/v1/projects/${HUB_PROJECT_ID}/locations/${REGION}/agentGateways/agw-sa-init" \
      -H "Authorization: Bearer $(get_token)" \
      -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" | jq -r '.name // empty')"
    [[ -n "${DEL_BOOT}" ]] && sleep 5
  fi
fi

for ROLE in \
  roles/agentgateway.serviceAgent \
  roles/compute.networkViewer \
  roles/compute.networkAdmin \
  roles/dns.reader \
  roles/certificatemanager.viewer; do
  gcloud projects add-iam-policy-binding "${HUB_PROJECT_ID}" \
    --member="serviceAccount:${AGW_SA}" \
    --role="${ROLE}" --condition=None --quiet >/dev/null
done

PSC_NA_URI="projects/${HUB_PROJECT_NUMBER}/regions/${REGION}/networkAttachments/na-agw-mcp-internal"
TRUST_CONFIG_URI="projects/${HUB_PROJECT_NUMBER}/locations/${REGION}/trustConfigs/tc-mcp-corp-internal"
ACT_URI="projects/${HUB_PROJECT_NUMBER}/locations/${REGION}/agentConnectivityTemplates/act-vpc-mcp-internal"
AGW_NAME="agw-vpc-${REGION}-ata"
AGW_URI="projects/${HUB_PROJECT_ID}/locations/${REGION}/agentGateways/${AGW_NAME}"

ACT_GET="https://networkservices.googleapis.com/v1/projects/${HUB_PROJECT_ID}/locations/${REGION}/agentConnectivityTemplates/act-vpc-mcp-internal"
if [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(get_token)" -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" "${ACT_GET}")" != "200" ]]; then
  info "Waiting 60s for Agent Gateway Service Agent IAM propagation..."
  sleep 60
  info "Creating AgentConnectivityTemplate 'act-vpc-mcp-internal'..."
  ACT_OP="$(curl -s -X POST \
    "https://networkservices.googleapis.com/v1/projects/${HUB_PROJECT_ID}/locations/${REGION}/agentConnectivityTemplates?agentConnectivityTemplateId=act-vpc-mcp-internal" \
    -H "Authorization: Bearer $(get_token)" \
    -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
    -H "Content-Type: application/json" \
    -d "{
      \"accessPath\": \"AGENT_TO_ANYWHERE\",
      \"deploymentModel\": \"CENTRALIZED\",
      \"egressNetworkConfig\": {
        \"networkAttachment\": \"${PSC_NA_URI}\",
        \"dnsPeeringConfig\": {
          \"domains\": [\"corp.internal.\"],
          \"targetNetwork\": \"projects/${HUB_PROJECT_ID}/global/networks/vpc-mcp-internal\"
        },
        \"vpcEgress\": \"PRIVATE_RANGES_ONLY\",
        \"tlsConfig\": {
          \"trustConfig\": \"${TRUST_CONFIG_URI}\",
          \"additionalRoots\": \"PUBLICLY_TRUSTED_ROOTS\"
        }
      }
    }" | jq -r '.name')"
  while [[ "$(curl -s -H "Authorization: Bearer $(get_token)" -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" "https://networkservices.googleapis.com/v1/${ACT_OP}" | jq -r '.done // false')" != "true" ]]; do
    sleep 5
  done
fi

AGW_GET="https://networkservices.googleapis.com/v1/projects/${HUB_PROJECT_ID}/locations/${REGION}/agentGateways/${AGW_NAME}"
if [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(get_token)" -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" "${AGW_GET}")" != "200" ]]; then
  info "Creating Hub AgentGateway '${AGW_NAME}'..."
  AGW_OP="$(curl -s -X POST \
    "https://networkservices.googleapis.com/v1/projects/${HUB_PROJECT_ID}/locations/${REGION}/agentGateways?agentGatewayId=${AGW_NAME}" \
    -H "Authorization: Bearer $(get_token)" \
    -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
    -H "Content-Type: application/json" \
    -d "{
      \"protocols\": [\"MCP\"],
      \"googleManaged\": {\"governedAccessPath\": \"AGENT_TO_ANYWHERE\"},
      \"agentConnectivityTemplate\": \"${ACT_URI}\",
      \"registries\": [\"//agentregistry.googleapis.com/projects/${HUB_PROJECT_ID}/locations/${REGION}\"]
    }" | jq -r '.name')"
  while [[ "$(curl -s -H "Authorization: Bearer $(get_token)" -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" "https://networkservices.googleapis.com/v1/${AGW_OP}" | jq -r '.done // false')" != "true" ]]; do
    sleep 10
  done
fi

if ! gcloud service-extensions authz-extensions describe agw-authz-ext-iap-v2 --location="${REGION}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  cat > cfg/iap-authz-ext.yaml <<EOF
name: agw-authz-ext-iap-v2
service: iap.googleapis.com
failOpen: false
timeout: 1s
metadata:
  iapPolicyVersion: "V2"
EOF
  gcloud service-extensions authz-extensions import agw-authz-ext-iap-v2 \
    --source=cfg/iap-authz-ext.yaml --location="${REGION}" --project="${HUB_PROJECT_ID}"
fi

AUTHZ_GET="https://networksecurity.googleapis.com/v1alpha1/projects/${HUB_PROJECT_ID}/locations/${REGION}/authzPolicies/${AGW_NAME}-authz-policy-iap"
if [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(get_token)" -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" "${AUTHZ_GET}")" != "200" ]]; then
  AUTHZ_OP="$(curl -s -X POST \
    "https://networksecurity.googleapis.com/v1alpha1/projects/${HUB_PROJECT_ID}/locations/${REGION}/authzPolicies?authz_policy_id=${AGW_NAME}-authz-policy-iap" \
    -H "Authorization: Bearer $(get_token)" \
    -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"${AGW_NAME}-authz-policy-iap\",
      \"policyProfile\": \"REQUEST_AUTHZ\",
      \"action\": \"CUSTOM\",
      \"target\": {\"resources\": [\"${AGW_URI}\"]},
      \"customProvider\": {
        \"authzExtension\": {
          \"resources\": [\"projects/${HUB_PROJECT_ID}/locations/${REGION}/authzExtensions/agw-authz-ext-iap-v2\"]
        }
      }
    }" | jq -r '.name')"
  while [[ "$(curl -s -H "Authorization: Bearer $(get_token)" -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" "https://networksecurity.googleapis.com/v1alpha1/${AUTHZ_OP}" | jq -r '.done // false')" != "true" ]]; do
    sleep 5
  done
fi

UAP_GET="https://iam.googleapis.com/v3/projects/${HUB_PROJECT_ID}/locations/global/accessPolicies/agent-gateway-allow-policy"
if [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(get_token)" -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" "${UAP_GET}")" != "200" ]]; then
  info "Creating IAM v3 Universal Access Policy 'agent-gateway-allow-policy'..."
  UAP_OP="$(curl -s -X POST \
    "https://iam.googleapis.com/v3/projects/${HUB_PROJECT_ID}/locations/global/accessPolicies?accessPolicyId=agent-gateway-allow-policy" \
    -H "Authorization: Bearer $(get_token)" \
    -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
    -H "Content-Type: application/json" \
    -d "{
      \"details\": {
        \"rules\": [
          {
            \"description\": \"Allow agent egress to Google APIs and registered Agent Registry services\",
            \"effect\": \"ALLOW\",
            \"principals\": [\"principalSet://${TRUST_DOMAIN}/*\"],
            \"operation\": {\"permissions\": [\"iap.googleapis.com/resources.egressViaIAP\"]},
            \"conditions\": {
              \"iap.googleapis.com\": {
                \"expression\": \"destination.unregistered.host.endsWith('googleapis.com') || destination.is_registered == true\"
              }
            }
          }
        ]
      }
    }" | jq -r '.name // empty')"
  if [[ -n "${UAP_OP}" ]]; then
    while [[ "$(curl -s -H "Authorization: Bearer $(get_token)" -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" "https://iam.googleapis.com/v3/${UAP_OP}" | jq -r '.done // false')" != "true" ]]; do
      sleep 3
    done
  fi
fi

BIND_GET="https://iam.googleapis.com/v3/projects/${HUB_PROJECT_ID}/locations/global/policyBindings/agent-gateway-allow-binding"
if [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(get_token)" -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" "${BIND_GET}")" != "200" ]]; then
  info "Binding IAM v3 Universal Access Policy to project '${HUB_PROJECT_ID}'..."
  BIND_OP="$(curl -s -X POST \
    "https://iam.googleapis.com/v3/projects/${HUB_PROJECT_ID}/locations/global/policyBindings?policyBindingId=agent-gateway-allow-binding" \
    -H "Authorization: Bearer $(get_token)" \
    -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
    -H "Content-Type: application/json" \
    -d "{
      \"policyKind\": \"ACCESS\",
      \"policy\": \"projects/${HUB_PROJECT_ID}/locations/global/accessPolicies/agent-gateway-allow-policy\",
      \"target\": {
        \"resource\": \"//cloudresourcemanager.googleapis.com/projects/${HUB_PROJECT_ID}\"
      }
    }" | jq -r '.name // empty')"
  if [[ -n "${BIND_OP}" ]]; then
    while [[ "$(curl -s -H "Authorization: Bearer $(get_token)" -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" "https://iam.googleapis.com/v3/${BIND_OP}" | jq -r '.done // false')" != "true" ]]; do
      sleep 3
    done
  fi
fi

info "Binding '${GE_APP_ID}' defaultEgressAgentGateway to '${AGW_NAME}'..."
curl -s -X PATCH \
  "https://${GE_LOCATION}-discoveryengine.googleapis.com/v1/projects/${HUB_PROJECT_ID}/locations/${GE_LOCATION}/collections/default_collection/engines/${GE_APP_ID}?updateMask=agentGatewaySetting.defaultEgressAgentGateway.name" \
  -H "Authorization: Bearer $(get_token)" \
  -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
  -H "Content-Type: application/json" \
  -d "{\"agentGatewaySetting\": {\"defaultEgressAgentGateway\": {\"name\": \"${AGW_URI}\"}}}" >/dev/null
ok "Hub Agent Gateway & IAM v3 UAP bound to '${GE_APP_ID}'."

# ------------------------------------------------------------------------------
# Stage 5: Deploy Internal Cloud Run MCP Server (mcp-countries-poc)
# ------------------------------------------------------------------------------
stage "Stage 5: Deploy Internal Cloud Run MCP Server (${APIGEE_PROJECT_ID})"

gcloud run deploy mcp-countries-poc \
  --source=mcp_countries_server \
  --region="${REGION}" \
  --project="${APIGEE_PROJECT_ID}" \
  --service-account="sa-mcp-countries@${APIGEE_PROJECT_ID}.iam.gserviceaccount.com" \
  --ingress=internal-and-cloud-load-balancing \
  --no-allow-unauthenticated \
  --port=8080 \
  --min-instances=0 \
  --max-instances=5 \
  --set-env-vars="GOOGLE_CLOUD_PROJECT=${APIGEE_PROJECT_ID},EXPECTED_OAUTH_CLIENT_ID=${OAUTH_CLIENT_ID}" \
  --quiet

gcloud run services add-iam-policy-binding mcp-countries-poc \
  --region="${REGION}" \
  --project="${APIGEE_PROJECT_ID}" \
  --member="serviceAccount:sa-apigee-invoker@${APIGEE_PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/run.invoker" >/dev/null

CLOUD_RUN_URL="$(gcloud run services describe mcp-countries-poc --region="${REGION}" --project="${APIGEE_PROJECT_ID}" --format='value(status.url)')"
save_env
ok "Cloud Run MCP server deployed: ${CLOUD_RUN_URL}"

# ------------------------------------------------------------------------------
# Stage 6: Provision Apigee X (EVALUATION, disableVpcPeering=true), KMS & Truststore
# ------------------------------------------------------------------------------
stage "Stage 6: Apigee X EVALUATION Org, KMS, Runtime Instance & Truststore"

if ! gcloud kms keyrings describe "apigee-keyring-${REGION}" --location="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud kms keyrings create "apigee-keyring-${REGION}" --location="${REGION}" --project="${APIGEE_PROJECT_ID}"
fi
if ! gcloud kms keys describe apigee-disk-key --keyring="apigee-keyring-${REGION}" --location="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud kms keys create apigee-disk-key --keyring="apigee-keyring-${REGION}" --location="${REGION}" --purpose=encryption --project="${APIGEE_PROJECT_ID}"
fi
KMS_KEY_ID="projects/${APIGEE_PROJECT_ID}/locations/${REGION}/keyRings/apigee-keyring-${REGION}/cryptoKeys/apigee-disk-key"
gcloud kms keys add-iam-policy-binding apigee-disk-key \
  --keyring="apigee-keyring-${REGION}" --location="${REGION}" \
  --member="serviceAccount:${APIGEE_SERVICE_AGENT}" \
  --role="roles/cloudkms.cryptoKeyEncrypterDecrypter" \
  --project="${APIGEE_PROJECT_ID}" >/dev/null

if [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(get_token)" "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}")" != "200" ]]; then
  info "Creating Apigee X EVALUATION organization '${APIGEE_PROJECT_ID}' (disableVpcPeering=true)..."
  OP_ORG="$(curl -s -X POST \
    "https://apigee.googleapis.com/v1/organizations?parent=projects/${APIGEE_PROJECT_ID}" \
    -H "Authorization: Bearer $(get_token)" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"${APIGEE_PROJECT_ID}\",
      \"displayName\": \"Apigee X Internal MCP Organization\",
      \"analyticsRegion\": \"${REGION}\",
      \"runtimeType\": \"CLOUD\",
      \"billingType\": \"EVALUATION\",
      \"disableVpcPeering\": true
    }" | jq -r '.name')"
  while [[ "$(curl -s -H "Authorization: Bearer $(get_token)" "https://apigee.googleapis.com/v1/${OP_ORG}" | jq -r '.done // false')" != "true" ]]; do
    sleep 10
  done
fi

if [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(get_token)" "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/environments/eval-mcp")" != "200" ]]; then
  curl -s -X POST \
    "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/environments" \
    -H "Authorization: Bearer $(get_token)" -H "Content-Type: application/json" \
    -d '{"name": "eval-mcp", "displayName": "Internal MCP Evaluation Env", "deploymentProxyType": "PROGRAMMABLE", "apiProxyType": "PROGRAMMABLE"}' >/dev/null
  sleep 5
fi

if [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(get_token)" "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/envgroups/internal-mcp-group")" != "200" ]]; then
  curl -s -X POST \
    "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/envgroups" \
    -H "Authorization: Bearer $(get_token)" -H "Content-Type: application/json" \
    -d "{\"name\": \"internal-mcp-group\", \"hostnames\": [\"${COUNTRIES_HOST}\"]}" >/dev/null
  sleep 5
  OP_EG="$(curl -s -X POST \
    "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/envgroups/internal-mcp-group/attachments" \
    -H "Authorization: Bearer $(get_token)" -H "Content-Type: application/json" \
    -d '{"environment": "eval-mcp"}' | jq -r '.name')"
  while [[ "$(curl -s -H "Authorization: Bearer $(get_token)" "https://apigee.googleapis.com/v1/${OP_EG}" | jq -r '.done // false')" != "true" ]]; do
    sleep 5
  done
fi

INST_URL="https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/instances/apigee-${REGION}"
INST_STATE="$(curl -s -H "Authorization: Bearer $(get_token)" "${INST_URL}" | jq -r '.state // "MISSING"')"
if [[ "${INST_STATE}" == "MISSING" ]]; then
  info "Provisioning Apigee X Runtime Instance 'apigee-${REGION}' (~20-25 minutes; single-tenant runtime)..."
  OP_INST="$(curl -s -X POST \
    "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/instances" \
    -H "Authorization: Bearer $(get_token)" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"apigee-${REGION}\",
      \"location\": \"${REGION}\",
      \"diskEncryptionKeyName\": \"${KMS_KEY_ID}\",
      \"consumerAcceptList\": [\"${HUB_PROJECT_ID}\", \"${APIGEE_PROJECT_ID}\"]
    }" | jq -r '.name')"
  ELAPSED=0
  while [[ "$(curl -s -H "Authorization: Bearer $(get_token)" "https://apigee.googleapis.com/v1/${OP_INST}" | jq -r '.done // false')" != "true" ]]; do
    printf "\r  ... Apigee runtime provisioning in progress (%dm %02ds elapsed)" $((ELAPSED/60)) $((ELAPSED%60))
    sleep 30
    ELAPSED=$((ELAPSED+30))
  done
  echo ""
elif [[ "${INST_STATE}" == "CREATING" ]]; then
  info "Apigee instance 'apigee-${REGION}' is currently CREATING; waiting until ACTIVE..."
  while [[ "$(curl -s -H "Authorization: Bearer $(get_token)" "${INST_URL}" | jq -r '.state // ""')" != "ACTIVE" ]]; do
    sleep 30
  done
fi

ATTACHED="$(curl -s -H "Authorization: Bearer $(get_token)" "${INST_URL}/attachments" | jq -r '[.attachments[]? | select(.environment == "eval-mcp")] | length')"
if [[ "${ATTACHED}" == "0" ]]; then
  OP_ATT="$(curl -s -X POST "${INST_URL}/attachments" \
    -H "Authorization: Bearer $(get_token)" -H "Content-Type: application/json" \
    -d '{"environment": "eval-mcp"}' | jq -r '.name')"
  while [[ "$(curl -s -H "Authorization: Bearer $(get_token)" "https://apigee.googleapis.com/v1/${OP_ATT}" | jq -r '.done // false')" != "true" ]]; do
    sleep 10
  done
fi

APIGEE_NB_SERVICE_ATTACHMENT="$(curl -s -H "Authorization: Bearer $(get_token)" "${INST_URL}" | jq -r '.serviceAttachment')"
save_env
ok "Apigee Northbound PSC Service Attachment: ${APIGEE_NB_SERVICE_ATTACHMENT}"

if [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(get_token)" "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/environments/eval-mcp/keystores/mcp-ca-truststore")" != "200" ]]; then
  curl -s -X POST "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/environments/eval-mcp/keystores" \
    -H "Authorization: Bearer $(get_token)" -H "Content-Type: application/json" \
    -d '{"name": "mcp-ca-truststore"}' >/dev/null
  curl -s -X POST "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/environments/eval-mcp/keystores/mcp-ca-truststore/aliases?alias=mcp-root-ca&format=keycertfile" \
    -H "Authorization: Bearer $(get_token)" -F "file=@certs/ca.crt" >/dev/null
fi
if [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(get_token)" "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/environments/eval-mcp/references/mcp-ca-truststore-ref")" != "200" ]]; then
  curl -s -X POST "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/environments/eval-mcp/references" \
    -H "Authorization: Bearer $(get_token)" -H "Content-Type: application/json" \
    -d '{"name": "mcp-ca-truststore-ref", "resourceType": "KeyStore", "refers": "mcp-ca-truststore"}' >/dev/null
fi

# ------------------------------------------------------------------------------
# Stage 7: Southbound Producer VPC, Internal HTTPS ALB, PSC & Two-Pass SAN TLS
# ------------------------------------------------------------------------------
stage "Stage 7: Southbound Producer VPC, PSC & Two-Pass EA_HOST SAN TLS"

if ! gcloud compute networks describe vpc-apigee-mcp --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute networks create vpc-apigee-mcp --subnet-mode=custom --project="${APIGEE_PROJECT_ID}"
fi
if ! gcloud compute networks subnets describe subnet-apigee-mcp-backend --region="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute networks subnets create subnet-apigee-mcp-backend \
    --network=vpc-apigee-mcp --region="${REGION}" --range=10.30.1.0/24 \
    --enable-private-ip-google-access --project="${APIGEE_PROJECT_ID}"
fi
if ! gcloud compute networks subnets describe subnet-apigee-mcp-proxy --region="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute networks subnets create subnet-apigee-mcp-proxy \
    --network=vpc-apigee-mcp --region="${REGION}" --purpose=REGIONAL_MANAGED_PROXY \
    --role=ACTIVE --range=10.30.2.0/24 --project="${APIGEE_PROJECT_ID}"
fi
if ! gcloud compute networks subnets describe subnet-apigee-mcp-psc-nat --region="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute networks subnets create subnet-apigee-mcp-psc-nat \
    --network=vpc-apigee-mcp --region="${REGION}" --purpose=PRIVATE_SERVICE_CONNECT \
    --range=10.30.3.0/24 --project="${APIGEE_PROJECT_ID}"
fi
if ! gcloud compute addresses describe ip-ilb-mcp-countries --region="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute addresses create ip-ilb-mcp-countries \
    --region="${REGION}" --subnet=subnet-apigee-mcp-backend \
    --addresses="${SB_ILB_IP}" --project="${APIGEE_PROJECT_ID}"
fi

if [[ ! -f certs/mcp-countries-sb.key ]]; then
  openssl genrsa -out certs/mcp-countries-sb.key 2048
fi
cat > certs/countries-sb-init.cnf <<EOF
[req]
distinguished_name = dn
req_extensions = v3_req
prompt = no
[dn]
CN = ${COUNTRIES_HOST}
[v3_req]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:${COUNTRIES_HOST},IP:${SB_ILB_IP},IP:${HUB_APIGEE_ILB_IP}
EOF
openssl req -new -key certs/mcp-countries-sb.key -out certs/mcp-countries-sb.csr -config certs/countries-sb-init.cnf
openssl x509 -req -in certs/mcp-countries-sb.csr -CA certs/ca.crt -CAkey certs/ca.key -CAcreateserial \
  -out certs/mcp-countries-sb-init.crt -days 825 -sha256 -extensions v3_req -extfile certs/countries-sb-init.cnf

if ! gcloud compute ssl-certificates describe cert-mcp-countries-sb-v1 --region="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute ssl-certificates create cert-mcp-countries-sb-v1 \
    --certificate=certs/mcp-countries-sb-init.crt --private-key=certs/mcp-countries-sb.key \
    --region="${REGION}" --project="${APIGEE_PROJECT_ID}"
fi
if ! gcloud compute network-endpoint-groups describe neg-mcp-countries-poc --region="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute network-endpoint-groups create neg-mcp-countries-poc \
    --region="${REGION}" --network-endpoint-type=serverless \
    --cloud-run-service=mcp-countries-poc --project="${APIGEE_PROJECT_ID}"
fi
if ! gcloud compute backend-services describe bs-mcp-countries-poc --region="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute backend-services create bs-mcp-countries-poc \
    --load-balancing-scheme=INTERNAL_MANAGED --protocol=HTTP \
    --region="${REGION}" --project="${APIGEE_PROJECT_ID}"
  gcloud compute backend-services add-backend bs-mcp-countries-poc \
    --region="${REGION}" --network-endpoint-group=neg-mcp-countries-poc \
    --network-endpoint-group-region="${REGION}" --project="${APIGEE_PROJECT_ID}"
fi
if ! gcloud compute url-maps describe um-mcp-countries-poc --region="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute url-maps create um-mcp-countries-poc \
    --default-service=bs-mcp-countries-poc --region="${REGION}" --project="${APIGEE_PROJECT_ID}"
fi
if ! gcloud compute target-https-proxies describe tp-mcp-countries-poc --region="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute target-https-proxies create tp-mcp-countries-poc \
    --url-map=um-mcp-countries-poc --ssl-certificates=cert-mcp-countries-sb-v1 \
    --region="${REGION}" --project="${APIGEE_PROJECT_ID}"
fi
if ! gcloud compute forwarding-rules describe fr-mcp-countries-poc --region="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute forwarding-rules create fr-mcp-countries-poc \
    --load-balancing-scheme=INTERNAL_MANAGED --network=vpc-apigee-mcp \
    --subnet=subnet-apigee-mcp-backend --address=ip-ilb-mcp-countries --ports=443 \
    --region="${REGION}" --target-https-proxy=tp-mcp-countries-poc \
    --target-https-proxy-region="${REGION}" --project="${APIGEE_PROJECT_ID}"
fi
if ! gcloud compute service-attachments describe sa-psc-mcp-countries --region="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute service-attachments create sa-psc-mcp-countries \
    --region="${REGION}" --producer-forwarding-rule=fr-mcp-countries-poc \
    --connection-preference=ACCEPT_AUTOMATIC --nat-subnets=subnet-apigee-mcp-psc-nat \
    --project="${APIGEE_PROJECT_ID}"
fi

SB_SERVICE_ATTACHMENT="projects/${APIGEE_PROJECT_ID}/regions/${REGION}/serviceAttachments/sa-psc-mcp-countries"
EA_URL="https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/endpointAttachments/ea-mcp-countries"
if [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(get_token)" "${EA_URL}")" != "200" ]]; then
  info "Creating Apigee Southbound EndpointAttachment 'ea-mcp-countries'..."
  OP_EA="$(curl -s -X POST \
    "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/endpointAttachments?endpointAttachmentId=ea-mcp-countries" \
    -H "Authorization: Bearer $(get_token)" -H "Content-Type: application/json" \
    -d "{\"location\": \"${REGION}\", \"serviceAttachment\": \"${SB_SERVICE_ATTACHMENT}\"}" | jq -r '.name')"
  while [[ "$(curl -s -H "Authorization: Bearer $(get_token)" "https://apigee.googleapis.com/v1/${OP_EA}" | jq -r '.done // false')" != "true" ]]; do
    sleep 10
  done
fi

EA_HOST="$(curl -s -H "Authorization: Bearer $(get_token)" "${EA_URL}" | jq -r '.host')"
save_env
ok "Apigee Southbound EndpointAttachment IP (EA_HOST): ${EA_HOST}"

cat > certs/countries-sb-ext.cnf <<EOF
[v3_req]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:${COUNTRIES_HOST},IP:${SB_ILB_IP},IP:${HUB_APIGEE_ILB_IP},IP:${EA_HOST}
EOF
openssl x509 -req -in certs/mcp-countries-sb.csr -CA certs/ca.crt -CAkey certs/ca.key -CAcreateserial \
  -out certs/mcp-countries-sb.crt -days 825 -sha256 -extensions v3_req -extfile certs/countries-sb-ext.cnf

if ! gcloud compute ssl-certificates describe cert-mcp-countries-sb-v2 --region="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute ssl-certificates create cert-mcp-countries-sb-v2 \
    --certificate=certs/mcp-countries-sb.crt --private-key=certs/mcp-countries-sb.key \
    --region="${REGION}" --project="${APIGEE_PROJECT_ID}"
fi
gcloud compute target-https-proxies update tp-mcp-countries-poc \
  --ssl-certificates=cert-mcp-countries-sb-v2 --region="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null
ok "Updated Southbound Target HTTPS Proxy with Pass-2 SAN certificate (IP:${EA_HOST})."

# ------------------------------------------------------------------------------
# Stage 8: Render, Package & Deploy Apigee X Proxy (country-facts-mcp)
# ------------------------------------------------------------------------------
stage "Stage 8: Deploy Apigee X Proxy 'country-facts-mcp'"

sed \
  -e "s|__EA_HOST__|${EA_HOST}|g" \
  -e "s|__CLOUD_RUN_URL__|${CLOUD_RUN_URL}|g" \
  apigee_bundles/country-facts-mcp/apiproxy/targets/default.xml.tmpl \
  > apigee_bundles/country-facts-mcp/apiproxy/targets/default.xml

(cd apigee_bundles/country-facts-mcp && zip -qr ../../country-facts-mcp.zip apiproxy)

REV="$(curl -s -X POST \
  "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/apis?action=import&name=country-facts-mcp" \
  -H "Authorization: Bearer $(get_token)" \
  -F "file=@country-facts-mcp.zip" | jq -r '.revision')"

curl -s -X POST \
  "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/environments/eval-mcp/apis/country-facts-mcp/revisions/${REV}/deployments?override=true&serviceAccount=sa-apigee-invoker@${APIGEE_PROJECT_ID}.iam.gserviceaccount.com" \
  -H "Authorization: Bearer $(get_token)" >/dev/null
ok "Deployed Apigee proxy 'country-facts-mcp' revision ${REV} as sa-apigee-invoker."

# ------------------------------------------------------------------------------
# Stage 9: Northbound Consumer PSC NEG, Hub ALB, DNS & Agent Registry
# ------------------------------------------------------------------------------
stage "Stage 9: Northbound PSC NEG, Hub HTTPS ALB, DNS & Agent Registry"

if ! gcloud compute addresses describe ip-ilb-apigee-countries --region="${REGION}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute addresses create ip-ilb-apigee-countries \
    --region="${REGION}" --subnet=subnet-ilb-backend \
    --addresses="${HUB_APIGEE_ILB_IP}" --project="${HUB_PROJECT_ID}"
fi

if [[ ! -f certs/mcp-countries.key ]]; then
  openssl genrsa -out certs/mcp-countries.key 2048
fi
cat > certs/countries-ext.cnf <<EOF
[req]
distinguished_name = dn
req_extensions = v3_req
prompt = no
[dn]
CN = ${COUNTRIES_HOST}
[v3_req]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:${COUNTRIES_HOST},IP:${HUB_APIGEE_ILB_IP}
EOF
openssl req -new -key certs/mcp-countries.key -out certs/mcp-countries.csr -config certs/countries-ext.cnf
openssl x509 -req -in certs/mcp-countries.csr -CA certs/ca.crt -CAkey certs/ca.key -CAcreateserial \
  -out certs/mcp-countries.crt -days 825 -sha256 -extensions v3_req -extfile certs/countries-ext.cnf

if ! gcloud compute ssl-certificates describe cert-mcp-countries-hub --region="${REGION}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute ssl-certificates create cert-mcp-countries-hub \
    --certificate=certs/mcp-countries.crt --private-key=certs/mcp-countries.key \
    --region="${REGION}" --project="${HUB_PROJECT_ID}"
fi
if ! gcloud compute network-endpoint-groups describe neg-psc-apigee-countries --region="${REGION}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute network-endpoint-groups create neg-psc-apigee-countries \
    --network-endpoint-type=private-service-connect \
    --psc-target-service="${APIGEE_NB_SERVICE_ATTACHMENT}" \
    --network=vpc-mcp-internal --subnet=subnet-ilb-backend \
    --region="${REGION}" --project="${HUB_PROJECT_ID}"
fi
if ! gcloud compute backend-services describe bs-apigee-countries --region="${REGION}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute backend-services create bs-apigee-countries \
    --load-balancing-scheme=INTERNAL_MANAGED --protocol=HTTPS \
    --region="${REGION}" --project="${HUB_PROJECT_ID}"
  gcloud compute backend-services add-backend bs-apigee-countries \
    --network-endpoint-group=neg-psc-apigee-countries \
    --network-endpoint-group-region="${REGION}" --region="${REGION}" --project="${HUB_PROJECT_ID}"
fi
if ! gcloud compute url-maps describe um-apigee-countries --region="${REGION}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute url-maps create um-apigee-countries \
    --default-service=bs-apigee-countries --region="${REGION}" --project="${HUB_PROJECT_ID}"
fi
if ! gcloud compute target-https-proxies describe tp-apigee-countries --region="${REGION}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute target-https-proxies create tp-apigee-countries \
    --url-map=um-apigee-countries --ssl-certificates=cert-mcp-countries-hub \
    --region="${REGION}" --project="${HUB_PROJECT_ID}"
fi
if ! gcloud compute forwarding-rules describe fr-apigee-countries --region="${REGION}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud compute forwarding-rules create fr-apigee-countries \
    --load-balancing-scheme=INTERNAL_MANAGED --network=vpc-mcp-internal \
    --subnet=subnet-ilb-backend --address=ip-ilb-apigee-countries --ports=443 \
    --region="${REGION}" --target-https-proxy=tp-apigee-countries \
    --target-https-proxy-region="${REGION}" --project="${HUB_PROJECT_ID}"
fi
if ! gcloud dns record-sets describe "${COUNTRIES_HOST}." --type=A --zone=zone-corp-internal --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  gcloud dns record-sets create "${COUNTRIES_HOST}." \
    --zone=zone-corp-internal --type=A --ttl=60 \
    --rrdatas="${HUB_APIGEE_ILB_IP}" --project="${HUB_PROJECT_ID}"
fi
AR_SVC_URL="https://agentregistry.googleapis.com/v1/projects/${HUB_PROJECT_ID}/locations/${REGION}/services/mcp-countries-poc"
if [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(get_token)" -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" "${AR_SVC_URL}")" != "200" ]]; then
  info "Registering 'mcp-countries-poc' in Hub Agent Registry..."
  TOOLSPEC_JSON="$(cat cfg/toolspec_countries.json)"
  AR_OP="$(curl -s -X POST \
    "https://agentregistry.googleapis.com/v1/projects/${HUB_PROJECT_ID}/locations/${REGION}/services?serviceId=mcp-countries-poc" \
    -H "Authorization: Bearer $(get_token)" \
    -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
    -H "Content-Type: application/json" \
    -d "{
      \"displayName\": \"Country Facts MCP Server (Apigee X + PSC + OAuth2)\",
      \"description\": \"Internal Country Facts StreamableHTTP MCP server hosted in ${APIGEE_PROJECT_ID} behind Apigee X over Northbound and Southbound PSC (${COUNTRIES_MCP_URL}).\",
      \"interfaces\": [{\"protocolBinding\": \"JSONRPC\", \"url\": \"${COUNTRIES_MCP_URL}\"}],
      \"mcpServerSpec\": {\"type\": \"TOOL_SPEC\", \"content\": ${TOOLSPEC_JSON}}
    }" | jq -r '.name // empty')"
  if [[ -n "${AR_OP}" ]]; then
    while [[ "$(curl -s -H "Authorization: Bearer $(get_token)" -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" "https://agentregistry.googleapis.com/v1/${AR_OP}" | jq -r '.done // false')" != "true" ]]; do
      sleep 3
    done
  fi
fi

MCP_COUNTRIES_REGISTRY_URI=""
for _ in {1..15}; do
  MCP_COUNTRIES_REGISTRY_URI="$(curl -s \
    -H "Authorization: Bearer $(get_token)" \
    -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
    "https://agentregistry.googleapis.com/v1alpha/projects/${HUB_PROJECT_ID}/locations/${REGION}/mcpServers" \
    | jq -r --arg url "${COUNTRIES_MCP_URL}" '.mcpServers[]? | select(.interfaces[]?.url == $url) | .name' | head -n 1)"
  [[ -n "${MCP_COUNTRIES_REGISTRY_URI}" ]] && break
  sleep 4
done
save_env
ok "Agent Registry MCP Server URI: ${MCP_COUNTRIES_REGISTRY_URI}"

# ------------------------------------------------------------------------------
# Stage 10: Connect Gemini Enterprise REGISTRY_MCP OAuth Data Connector & Verify
# ------------------------------------------------------------------------------
stage "Stage 10: Connect Gemini Enterprise & Run Verification"

if [[ -z "${GE_COUNTRIES_COLLECTION_ID:-}" ]]; then
  COLLECTION_DISPLAY_NAME="mcp-countries-apigee-collection"
  COLLECTION_ID="mcp-countries-apigee-collection-$(date +%s)"

  curl -s -X POST \
    "https://${GE_LOCATION}-discoveryengine.googleapis.com/v1alpha/projects/${HUB_PROJECT_ID}/locations/${GE_LOCATION}:setUpDataConnector" \
    -H "Authorization: Bearer $(get_token)" \
    -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
    -H "Content-Type: application/json" \
    -d "{
      \"collectionId\": \"${COLLECTION_ID}\",
      \"collectionDisplayName\": \"${COLLECTION_DISPLAY_NAME}\",
      \"dataConnector\": {
        \"dataSource\": \"custom_mcp\",
        \"dataSourceVersion\": 1,
        \"params\": {\"oauth_access_token\": \"unused\"},
        \"refreshInterval\": \"86400s\",
        \"entities\": [{\"entityName\": \"mcp_data\"}],
        \"connectorModes\": [\"FEDERATED\"],
        \"actionConfig\": {
          \"isActionConfigured\": true,
          \"createBapConnection\": true,
          \"actionParams\": {
            \"auth_type\": \"OAUTH\",
            \"instance_uri\": \"${COUNTRIES_MCP_URL}\",
            \"auth_uri\": \"https://accounts.google.com/o/oauth2/v2/auth\",
            \"auth_uri_params\": \"&access_type=offline&prompt=consent\",
            \"token_uri\": \"https://oauth2.googleapis.com/token\",
            \"client_id\": \"${OAUTH_CLIENT_ID}\",
            \"client_secret\": \"${OAUTH_CLIENT_SECRET}\",
            \"scopes\": \"openid email profile\",
            \"client_secret_basic_override\": true,
            \"mcp_server_source\": \"REGISTRY_MCP\",
            \"registry_mcp_server_name\": \"${MCP_COUNTRIES_REGISTRY_URI}\",
            \"mcp_agent_instructions\": \"COUNTRY FACTS APIGEE MCP AGENT: Always invoke list_countries, get_country_facts, or get_authenticated_caller for any question about countries, capitals, ISO codes, populations, currencies, languages, timezones, Japan, Brazil, Norway, Kenya, Canada, Australia, or Apigee X proxy mediation.\",
            \"use_agent_gateway_egress\": true,
            \"agent_gateway_engine\": \"projects/${HUB_PROJECT_ID}/locations/global/collections/default_collection/engines/${GE_APP_ID}\"
          }
        }
      }
    }" >/dev/null

  while true; do
    GE_COUNTRIES_COLLECTION_ID="$(curl -s \
      "https://${GE_LOCATION}-discoveryengine.googleapis.com/v1alpha/projects/${HUB_PROJECT_ID}/locations/${GE_LOCATION}/collections" \
      -H "Authorization: Bearer $(get_token)" \
      -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
      | jq -r --arg cid "${COLLECTION_ID}" '.collections[]? | select(.name | endswith("/" + $cid)) | .name | split("/") | last')"
    [[ -n "${GE_COUNTRIES_COLLECTION_ID}" ]] && break
    sleep 5
  done
  save_env
fi

curl -s -X PATCH \
  "https://discoveryengine.googleapis.com/v1alpha/projects/${HUB_PROJECT_ID}/locations/global/collections/${GE_COUNTRIES_COLLECTION_ID}/dataConnector?updateMask=actionConfig" \
  -H "Authorization: Bearer $(get_token)" \
  -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"projects/${HUB_PROJECT_ID}/locations/global/collections/${GE_COUNTRIES_COLLECTION_ID}/dataConnector\",
    \"actionConfig\": {
      \"isActionConfigured\": true,
      \"createBapConnection\": true,
      \"actionParams\": {
        \"auth_type\": \"OAUTH\",
        \"instance_uri\": \"${COUNTRIES_MCP_URL}\",
        \"auth_uri\": \"https://accounts.google.com/o/oauth2/v2/auth\",
        \"auth_uri_params\": \"&access_type=offline&prompt=consent\",
        \"token_uri\": \"https://oauth2.googleapis.com/token\",
        \"client_id\": \"${OAUTH_CLIENT_ID}\",
        \"client_secret\": \"${OAUTH_CLIENT_SECRET}\",
        \"scopes\": \"openid email profile\",
        \"client_secret_basic_override\": true,
        \"mcp_server_source\": \"REGISTRY_MCP\",
        \"registry_mcp_server_name\": \"${MCP_COUNTRIES_REGISTRY_URI}\",
        \"mcp_agent_instructions\": \"COUNTRY FACTS APIGEE MCP AGENT: Always invoke list_countries, get_country_facts, or get_authenticated_caller for any question about countries, capitals, ISO codes, populations, currencies, languages, timezones, Japan, Brazil, Norway, Kenya, Canada, Australia, or Apigee X proxy mediation.\",
        \"use_agent_gateway_egress\": true,
        \"agent_gateway_engine\": \"projects/${HUB_PROJECT_ID}/locations/global/collections/default_collection/engines/${GE_APP_ID}\"
      }
    }
  }" >/dev/null
ok "Activated Gemini Enterprise REGISTRY_MCP connector (${GE_COUNTRIES_COLLECTION_ID})."

./verify.sh
