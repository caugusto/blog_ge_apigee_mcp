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
LOG_FILE="${SCRIPT_DIR}/deploy.log"
PID_FILE="${SCRIPT_DIR}/.deploy.pid"

BACKGROUND_MODE=true
UNATTENDED_WORKER=false
RECONFIGURE=false
REBUILD_MCP=false
REDEPLOY_PROXY=false
REBUILD_VERIFIER=false
ORG_POLICY_JUST_OVERRIDDEN=false
WORKER_EXTRA_ARGS=()
for arg in "$@"; do
  case "${arg}" in
    --background|-b) BACKGROUND_MODE=true ;;
    --foreground|-f) BACKGROUND_MODE=false ;;
    --unattended-worker) UNATTENDED_WORKER=true; BACKGROUND_MODE=false ;;
    --reconfigure) RECONFIGURE=true ;;
    --rebuild-mcp) REBUILD_MCP=true; WORKER_EXTRA_ARGS+=("--rebuild-mcp") ;;
    --redeploy-proxy) REDEPLOY_PROXY=true; WORKER_EXTRA_ARGS+=("--redeploy-proxy") ;;
    --rebuild-verifier) REBUILD_VERIFIER=true; WORKER_EXTRA_ARGS+=("--rebuild-verifier") ;;
    --org-policy-updated) ORG_POLICY_JUST_OVERRIDDEN=true ;;
  esac
done

# ------------------------------------------------------------------------------
# Pretty logging, LRO & Idempotency helpers
# ------------------------------------------------------------------------------
if [[ -t 1 ]]; then
  BLUE="\033[1;34m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; NC="\033[0m"
else
  BLUE=""; GREEN=""; YELLOW=""; RED=""; NC=""
  export CLOUDSDK_CORE_DISABLE_COLOR=1
fi

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
skip()  { echo -e "${GREEN}[SKIP]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
stage() { echo -e "\n${BLUE}==============================================================================${NC}\n${BLUE} $*${NC}\n${BLUE}==============================================================================${NC}"; }

DETACHED_CLEANLY=false
IAM_ROLE_GRANTED=false
LAST_ERR_LINE=""
STOP_SIGNAL=""
SLEEP_PID=""
rm -f cfg/.iam_*.json 2>/dev/null || true

interruptible_sleep() {
  sleep "$1" &
  SLEEP_PID=$!
  wait "${SLEEP_PID}" 2>/dev/null || true
  SLEEP_PID=""
}

on_signal() {
  STOP_SIGNAL="$1"
  if [[ -n "${SLEEP_PID}" ]]; then
    kill "${SLEEP_PID}" 2>/dev/null || true
    SLEEP_PID=""
  fi
  if [[ "${STOP_SIGNAL}" == "SIGINT" ]]; then
    exit 130
  else
    exit 143
  fi
}

on_exit() {
  local rc=$?
  if [[ -n "${SLEEP_PID}" ]]; then
    kill "${SLEEP_PID}" 2>/dev/null || true
    SLEEP_PID=""
  fi
  rm -f cfg/.iam_*.json 2>/dev/null || true
  if [[ "${UNATTENDED_WORKER}" == "true" ]]; then
    rm -f "${PID_FILE}" 2>/dev/null || true
  fi
  if [[ "${DETACHED_CLEANLY}" == "true" ]]; then
    return 0
  fi
  echo ""
  if [[ -n "${STOP_SIGNAL}" ]]; then
    echo -e "${RED}==============================================================================${NC}" >&2
    echo -e "${RED} [STOPPED] Received termination signal (${STOP_SIGNAL}); exited cleanly (code ${rc}).${NC}" >&2
    echo -e "${RED} Re-run './deploy.sh' to resume from this exact stage${NC}" >&2
    echo -e "${RED} (all completed resources and IAM bindings will be [SKIP]ped).${NC}" >&2
    echo -e "${RED}==============================================================================${NC}" >&2
  elif [[ "${rc}" -ne 0 ]]; then
    local loc_msg=""
    [[ -n "${LAST_ERR_LINE}" ]] && loc_msg=" (near line ${LAST_ERR_LINE})"
    echo -e "${RED}==============================================================================${NC}" >&2
    echo -e "${RED} [STOPPED] Deployment exited with code ${rc}${loc_msg}.${NC}" >&2
    echo -e "${RED} Re-run './deploy.sh' to resume from this exact stage${NC}" >&2
    echo -e "${RED} (all completed resources and IAM bindings will be [SKIP]ped).${NC}" >&2
    echo -e "${RED}==============================================================================${NC}" >&2
  else
    echo -e "${GREEN}==============================================================================${NC}"
    echo -e "${GREEN} [COMPLETE] End-to-end deployment & verification finished successfully!${NC}"
    echo -e "${GREEN}==============================================================================${NC}"
  fi
}
trap 'LAST_ERR_LINE=$LINENO' ERR
trap 'on_signal SIGINT' INT
trap 'on_signal SIGTERM' TERM
trap 'on_exit' EXIT

if [[ "${UNATTENDED_WORKER}" != "true" && -f "${PID_FILE}" ]]; then
  OLD_PID="$(cat "${PID_FILE}" 2>/dev/null || true)"
  if [[ -n "${OLD_PID}" ]] && kill -0 "${OLD_PID}" 2>/dev/null; then
    warn "Stopping previous background worker (PID ${OLD_PID})..."
    kill "${OLD_PID}" 2>/dev/null || true
    sleep 1
  fi
  rm -f "${PID_FILE}"
fi

get_token() {
  gcloud auth print-access-token 2>/dev/null
}

ensure_project_apis() {
  local proj="$1"
  shift
  local desired_apis=("$@")
  local enabled_list
  enabled_list="$(gcloud services list --enabled --project="${proj}" --format='value(config.name)' 2>/dev/null || true)"
  local missing_apis=()
  for api in "${desired_apis[@]}"; do
    if ! grep -Fxq "${api}" <<< "${enabled_list}"; then
      missing_apis+=("${api}")
    fi
  done
  if [[ "${#missing_apis[@]}" -eq 0 ]]; then
    skip "All ${#desired_apis[@]} required APIs already enabled on '${proj}'."
    return 0
  fi
  info "Enabling ${#missing_apis[@]} missing API(s) on '${proj}': ${missing_apis[*]}..."
  for ((i=0; i<${#missing_apis[@]}; i+=15)); do
    local batch=("${missing_apis[@]:i:15}")
    if ! gcloud services enable "${batch[@]}" --project="${proj}"; then
      warn "Batch API enablement had a warning; enabling batch APIs individually..."
      for api in "${batch[@]}"; do
        gcloud services enable "${api}" --project="${proj}" 2>/dev/null || warn "Optional/preview API '${api}' skipped."
      done
    fi
  done
  ok "Enabled missing APIs on '${proj}'."
}

get_project_iam_cache() {
  local proj="$1"
  local cache_file="cfg/.iam_${proj}.json"
  if [[ ! -f "${cache_file}" ]]; then
    gcloud projects get-iam-policy "${proj}" --format=json > "${cache_file}"
  fi
  echo "${cache_file}"
}

project_has_member_any_role() {
  local proj="$1"
  local member="$2"
  local cache_file count
  cache_file="$(get_project_iam_cache "${proj}")"
  count="$(jq -r --arg m "${member}" '[.bindings[]? | select(.members[]? == $m)] | length' "${cache_file}" 2>/dev/null || echo "0")"
  [[ "${count}" != "0" ]]
}

ensure_project_iam_roles() {
  local proj="$1"
  local member="$2"
  shift 2
  local cache_file
  cache_file="$(get_project_iam_cache "${proj}")"
  for role in "$@"; do
    local has_role
    has_role="$(jq -r --arg r "${role}" --arg m "${member}" \
      '[.bindings[]? | select(.role == $r and (.condition == null) and (.members[]? == $m))] | length' \
      "${cache_file}" 2>/dev/null || echo "0")"
    if [[ "${has_role}" != "0" ]]; then
      skip "IAM ${role} already granted to ${member} on '${proj}'."
    else
      info "Granting ${role} to ${member} on '${proj}'..."
      if gcloud projects add-iam-policy-binding "${proj}" \
        --member="${member}" \
        --role="${role}" \
        --condition=None --quiet --format=json > "${cache_file}.tmp" 2>/dev/null; then
        mv "${cache_file}.tmp" "${cache_file}"
        IAM_ROLE_GRANTED=true
      else
        rm -f "${cache_file}.tmp"
        warn "Could not grant ${role} to ${member} on '${proj}' (continuing)."
      fi
    fi
  done
}

ensure_sa_iam_roles() {
  local proj="$1"
  local sa_email="$2"
  local member="$3"
  shift 3
  local policy_json
  policy_json="$(gcloud iam service-accounts get-iam-policy "${sa_email}" --project="${proj}" --format=json 2>/dev/null || echo '{}')"
  for role in "$@"; do
    local has_role
    has_role="$(echo "${policy_json}" | jq -r --arg r "${role}" --arg m "${member}" \
      '[.bindings[]? | select(.role == $r and (.members[]? == $m))] | length' 2>/dev/null || echo "0")"
    if [[ "${has_role}" != "0" ]]; then
      skip "Service Account IAM ${role} already granted on '${sa_email}'."
    else
      info "Granting ${role} on '${sa_email}' to ${member}..."
      policy_json="$(gcloud iam service-accounts add-iam-policy-binding "${sa_email}" \
        --member="${member}" \
        --role="${role}" \
        --project="${proj}" --format=json)"
    fi
  done
}

ensure_run_invoker() {
  local proj="$1"
  local region="$2"
  local svc="$3"
  local member="$4"
  local policy_json has_role
  policy_json="$(gcloud run services get-iam-policy "${svc}" --region="${region}" --project="${proj}" --format=json 2>/dev/null || echo '{}')"
  has_role="$(echo "${policy_json}" | jq -r --arg m "${member}" \
    '[.bindings[]? | select(.role == "roles/run.invoker" and (.members[]? == $m))] | length' 2>/dev/null || echo "0")"
  if [[ "${has_role}" != "0" ]]; then
    skip "Cloud Run roles/run.invoker already granted to ${member} on '${svc}'."
  else
    info "Granting Cloud Run roles/run.invoker to ${member} on '${svc}'..."
    gcloud run services add-iam-policy-binding "${svc}" \
      --region="${region}" \
      --project="${proj}" \
      --member="${member}" \
      --role="roles/run.invoker" >/dev/null
    ok "Granted roles/run.invoker on '${svc}'."
  fi
}

ensure_kms_iam_role() {
  local proj="$1"
  local region="$2"
  local keyring="$3"
  local key="$4"
  local member="$5"
  local role="$6"
  local policy_json has_role
  policy_json="$(gcloud kms keys get-iam-policy "${key}" --keyring="${keyring}" --location="${region}" --project="${proj}" --format=json 2>/dev/null || echo '{}')"
  has_role="$(echo "${policy_json}" | jq -r --arg r "${role}" --arg m "${member}" \
    '[.bindings[]? | select(.role == $r and (.members[]? == $m))] | length' 2>/dev/null || echo "0")"
  if [[ "${has_role}" != "0" ]]; then
    skip "KMS IAM ${role} already granted on key '${key}'."
  else
    info "Granting ${role} on KMS key '${key}' to ${member}..."
    gcloud kms keys add-iam-policy-binding "${key}" \
      --keyring="${keyring}" --location="${region}" \
      --member="${member}" \
      --role="${role}" \
      --project="${proj}" >/dev/null
    ok "Granted ${role} on KMS key '${key}'."
  fi
}

ensure_org_policy_unenforced() {
  local proj_id="$1"
  local proj_num="$2"
  local constraint="$3"
  local eff_json=""
  local eff_err=""

  for attempt in {1..8}; do
    if eff_json="$(gcloud org-policies describe "${constraint}" --project="${proj_id}" --effective --format=json 2>"cfg/.orgpol_err")"; then
      rm -f "cfg/.orgpol_err"
      break
    fi
    eff_err="$(cat "cfg/.orgpol_err" 2>/dev/null || true)"
    rm -f "cfg/.orgpol_err"
    if [[ "${eff_err}" == *"NOT_FOUND"* ]]; then
      skip "Org policy '${constraint}' has no active enforcement on '${proj_id}'."
      return 0
    fi
    if [[ "${attempt}" -lt 8 && ( "${eff_err}" == *"SERVICE_DISABLED"* || "${eff_err}" == *"not been used"* || "${eff_err}" == *"not enabled"* || "${eff_err}" == *"UNAVAILABLE"* || "${eff_err}" == *"BACKEND_ERROR"* ) ]]; then
      info "Waiting 10s for orgpolicy.googleapis.com enablement to propagate on '${proj_id}' (attempt ${attempt}/8)..."
      interruptible_sleep 10
      continue
    fi
    break
  done

  if [[ -n "${eff_json}" ]]; then
    local enforced_count unenforced_count
    enforced_count="$(echo "${eff_json}" | jq -r '[.spec.rules[]? | select(.enforce == true)] | length' 2>/dev/null || echo "1")"
    unenforced_count="$(echo "${eff_json}" | jq -r '[.spec.rules[]? | select(.enforce == false)] | length' 2>/dev/null || echo "0")"
    if [[ "${enforced_count}" == "0" && "${unenforced_count}" != "0" ]]; then
      skip "Org policy '${constraint}' is already unenforced (enforce=false) on '${proj_id}'."
      return 0
    fi
  fi

  info "Disabling Organization Policy 'constraints/${constraint}' (enforce=false) on '${proj_id}'..."
  cat > "cfg/policy_${constraint}.yaml" <<EOF
name: projects/${proj_num}/policies/${constraint}
spec:
  rules:
  - enforce: false
EOF

  local set_out=""
  local set_ok=false
  for attempt in {1..8}; do
    if set_out="$(gcloud org-policies set-policy "cfg/policy_${constraint}.yaml" --project="${proj_id}" 2>&1)"; then
      set_ok=true
      break
    fi
    if [[ "${attempt}" -lt 8 && ( "${set_out}" == *"SERVICE_DISABLED"* || "${set_out}" == *"not been used"* || "${set_out}" == *"not enabled"* || "${set_out}" == *"UNAVAILABLE"* || "${set_out}" == *"BACKEND_ERROR"* || "${set_out}" == *"ABORTED"* || "${set_out}" == *"CONCURRENT"* ) ]]; then
      warn "orgpolicy.googleapis.com still warming up on '${proj_id}' (attempt ${attempt}/8); retrying in 10s..."
      interruptible_sleep 10
      continue
    fi
    break
  done

  if [[ "${set_ok}" != "true" ]]; then
    err "Failed to disable 'constraints/${constraint}' on '${proj_id}': ${set_out}"
    err "Ensure your account holds 'roles/orgpolicy.policyAdmin' at the Organization/Folder/Project level, then re-run ./deploy.sh."
    exit 1
  fi

  for _ in {1..12}; do
    local poll_eff poll_enf
    poll_eff="$(gcloud org-policies describe "${constraint}" --project="${proj_id}" --effective --format=json 2>/dev/null || true)"
    poll_enf="$(echo "${poll_eff}" | jq -r '[.spec.rules[]? | select(.enforce == true)] | length' 2>/dev/null || echo "1")"
    if [[ -n "${poll_eff}" && "${poll_enf}" == "0" ]]; then
      break
    fi
    interruptible_sleep 5
  done

  ORG_POLICY_JUST_OVERRIDDEN=true
  ok "Disabled 'constraints/${constraint}' (enforce=false) on '${proj_id}'."
}

wait_apigee_idle() {
  local announced=false
  local elapsed=0
  for _ in {1..360}; do
    local in_prog
    in_prog="$(curl -s -H "Authorization: Bearer $(get_token)" \
      "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/operations" \
      | jq -r '[.operations[]? | select(.metadata.state == "IN_PROGRESS")] | length' 2>/dev/null || echo "0")"
    [[ "${in_prog:-0}" == "0" ]] && return 0
    if [[ "${announced}" == "false" ]]; then
      info "Waiting for ${in_prog} in-progress Apigee operation(s) on '${APIGEE_PROJECT_ID}' to settle..."
      announced=true
    elif (( elapsed > 0 && elapsed % 60 == 0 )); then
      echo "  ... Apigee operation still in progress ($((elapsed/60))m elapsed)"
    fi
    interruptible_sleep 5
    elapsed=$((elapsed + 5))
  done
}

wait_apigee_op() {
  local resp_json="$1"
  local label="$2"
  local sleep_sec="${3:-10}"
  if echo "${resp_json}" | jq -e '.error' >/dev/null 2>&1; then
    err "Failed starting ${label}: $(echo "${resp_json}" | jq -c '.error')"
    exit 1
  fi
  local op_name
  op_name="$(echo "${resp_json}" | jq -r '.name // empty' 2>/dev/null || true)"
  if [[ -z "${op_name}" || "${op_name}" == "null" ]]; then
    err "Failed starting ${label}: ${resp_json}"
    exit 1
  fi
  # Some Apigee endpoints return the created resource synchronously instead of an Operation
  if [[ "${op_name}" != organizations/*/operations/* ]]; then
    return 0
  fi
  local elapsed=0
  while true; do
    local poll_json done_flag
    poll_json="$(curl -s -H "Authorization: Bearer $(get_token)" "https://apigee.googleapis.com/v1/${op_name}")"
    done_flag="$(echo "${poll_json}" | jq -r '.done // false' 2>/dev/null || echo "false")"
    if [[ "${done_flag}" == "true" ]]; then
      if echo "${poll_json}" | jq -e '.error' >/dev/null 2>&1; then
        err "${label} failed: $(echo "${poll_json}" | jq -c '.error')"
        exit 1
      fi
      [[ -t 1 && "${sleep_sec}" -ge 20 ]] && echo ""
      return 0
    fi
    if (( sleep_sec >= 20 )); then
      if [[ -t 1 ]]; then
        printf "\r  ... %s in progress (%dm %02ds elapsed)" "${label}" $((elapsed/60)) $((elapsed%60))
      elif (( elapsed % 60 == 0 )); then
        echo "  ... ${label} in progress ($((elapsed/60))m elapsed)"
      fi
    fi
    interruptible_sleep "${sleep_sec}"
    elapsed=$((elapsed + sleep_sec))
  done
}

apigee_post_and_wait() {
  local url="$1"
  local body="$2"
  local label="$3"
  local sleep_sec="${4:-10}"
  local resp=""
  for attempt in 1 2 3; do
    wait_apigee_idle
    resp="$(curl -s -X POST "${url}" \
      -H "Authorization: Bearer $(get_token)" \
      -H "Content-Type: application/json" \
      -d "${body}")"
    if echo "${resp}" | jq -e '.error' >/dev/null 2>&1; then
      local code err_status
      code="$(echo "${resp}" | jq -r '.error.code // 0' 2>/dev/null || echo "0")"
      err_status="$(echo "${resp}" | jq -r '.error.status // ""' 2>/dev/null || echo "")"
      if [[ "${attempt}" -lt 3 && "${err_status}" != "INVALID_ARGUMENT" && ( "${code}" == "400" || "${code}" == "409" || "${code}" == "503" ) ]]; then
        warn "${label} temporarily locked by Apigee control plane (HTTP ${code}); retrying in 10s (attempt ${attempt}/3)..."
        interruptible_sleep 10
        continue
      fi
    fi
    break
  done
  wait_apigee_op "${resp}" "${label}" "${sleep_sec}"
  interruptible_sleep 3
  wait_apigee_idle
}

wait_gcp_op() {
  local api_base="$1"
  local resp_json="$2"
  local label="$3"
  local sleep_sec="${4:-5}"
  if echo "${resp_json}" | jq -e '.error' >/dev/null 2>&1; then
    err "Failed starting ${label}: $(echo "${resp_json}" | jq -c '.error')"
    exit 1
  fi
  local op_name
  op_name="$(echo "${resp_json}" | jq -r '.name // empty' 2>/dev/null || true)"
  if [[ -z "${op_name}" || "${op_name}" == "null" ]]; then
    err "Failed starting ${label}: ${resp_json}"
    exit 1
  fi
  if [[ "${op_name}" != */operations/* ]]; then
    return 0
  fi
  while true; do
    local poll_json done_flag
    poll_json="$(curl -s -H "Authorization: Bearer $(get_token)" -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" "${api_base}/${op_name}")"
    done_flag="$(echo "${poll_json}" | jq -r '.done // false' 2>/dev/null || echo "false")"
    if [[ "${done_flag}" == "true" ]]; then
      if echo "${poll_json}" | jq -e '.error' >/dev/null 2>&1; then
        err "${label} failed: $(echo "${poll_json}" | jq -c '.error')"
        exit 1
      fi
      return 0
    fi
    interruptible_sleep "${sleep_sec}"
  done
}

networkservices_post_with_iam_retry() {
  local url="$1"
  local body="$2"
  local label="$3"
  local poll_sleep="${4:-5}"
  for attempt in {1..8}; do
    local resp_json op_name
    resp_json="$(curl -s -X POST "${url}" \
      -H "Authorization: Bearer $(get_token)" \
      -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
      -H "Content-Type: application/json" \
      -d "${body}")"
    if echo "${resp_json}" | jq -e '.error' >/dev/null 2>&1; then
      local err_str
      err_str="$(echo "${resp_json}" | jq -c '.error')"
      if [[ "${attempt}" -lt 8 && ( "${err_str}" == *"permission"* || "${err_str}" == *"PERMISSION_DENIED"* ) ]]; then
        warn "${label}: Service Agent IAM still propagating (attempt ${attempt}/8); retrying in 30s..."
        interruptible_sleep 30
        continue
      fi
      err "Failed starting ${label}: ${err_str}"
      exit 1
    fi
    op_name="$(echo "${resp_json}" | jq -r '.name // empty' 2>/dev/null || true)"
    if [[ -z "${op_name}" || "${op_name}" == "null" ]]; then
      err "Failed starting ${label}: ${resp_json}"
      exit 1
    fi
    local retry_needed=false
    while true; do
      local poll_json done_flag
      poll_json="$(curl -s -H "Authorization: Bearer $(get_token)" -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" "https://networkservices.googleapis.com/v1/${op_name}")"
      done_flag="$(echo "${poll_json}" | jq -r '.done // false' 2>/dev/null || echo "false")"
      if [[ "${done_flag}" == "true" ]]; then
        if echo "${poll_json}" | jq -e '.error' >/dev/null 2>&1; then
          local op_err
          op_err="$(echo "${poll_json}" | jq -c '.error')"
          if [[ "${attempt}" -lt 8 && ( "${op_err}" == *"does not have permission"* || "${op_err}" == *"PERMISSION_DENIED"* ) ]]; then
            warn "${label}: Agent Gateway Service Agent IAM still propagating globally (attempt ${attempt}/8); retrying in 30s..."
            retry_needed=true
            break
          fi
          err "${label} failed: ${op_err}"
          exit 1
        fi
        return 0
      fi
      interruptible_sleep "${poll_sleep}"
    done
    if [[ "${retry_needed}" == "true" ]]; then
      interruptible_sleep 30
      continue
    fi
    return 0
  done
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

if [[ "${UNATTENDED_WORKER}" != "true" ]]; then
  # ----------------------------------------------------------------------------
  # Stage 0: Preflight & Interactive Configuration Wizard
  # ----------------------------------------------------------------------------
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

  HAS_ACTIVE_ENV=false
  if [[ -f "${ENV_FILE}" ]]; then
    info "Loading saved configuration from ${ENV_FILE}..."
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    if [[ -n "${HUB_PROJECT_ID:-}" ]]; then
      HUB_LIFE="$(gcloud projects describe "${HUB_PROJECT_ID}" --format='value(lifecycleState)' 2>/dev/null || echo 'MISSING')"
      if [[ "${HUB_LIFE}" == "DELETE_REQUESTED" ]]; then
        warn "Saved Hub project '${HUB_PROJECT_ID}' is pending deletion; clearing stale project IDs from ${ENV_FILE}."
        HUB_PROJECT_ID=""; APIGEE_PROJECT_ID=""; CLOUD_RUN_URL=""; EA_HOST=""
        APIGEE_NB_SERVICE_ATTACHMENT=""; MCP_COUNTRIES_REGISTRY_URI=""; GE_COUNTRIES_COLLECTION_ID=""
      elif [[ "${HUB_LIFE}" == "ACTIVE" && -n "${BILLING_ACCOUNT_ID:-}" && -n "${APIGEE_PROJECT_ID:-}" && "${RECONFIGURE}" != "true" ]]; then
        HAS_ACTIVE_ENV=true
      fi
    fi
  fi

  if [[ "${HAS_ACTIVE_ENV}" == "true" ]]; then
    ok "Auto-resuming with active configuration from ${ENV_FILE} (Hub: ${HUB_PROJECT_ID}, Apigee: ${APIGEE_PROJECT_ID}). Pass --reconfigure to change."
  else
    RAND_SUFFIX="$(date +%s | tail -c 5)"
    DEFAULT_BILLING="$(gcloud billing accounts list --filter='open=true' --format='value(name)' 2>/dev/null | head -n 1 | sed 's|billingAccounts/||')"

    echo ""
    info "Press Enter to accept [default] values, or type a custom value:"
    echo ""

    if [[ -z "${BILLING_ACCOUNT_ID:-}" || "${RECONFIGURE}" == "true" ]]; then
      if [[ -n "${DEFAULT_BILLING}" ]]; then
        info "Detected open billing accounts:"
        gcloud billing accounts list --filter="open=true" --format="table(name.basename(),displayName,open)" || true
      fi
      DEF_BILL="${BILLING_ACCOUNT_ID:-${DEFAULT_BILLING}}"
      read -r -p "1. Google Cloud Billing Account ID [${DEF_BILL}]: " INPUT_BILLING
      BILLING_ACCOUNT_ID="${INPUT_BILLING:-${DEF_BILL}}"
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
  fi

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
else
  # Unattended background worker: load saved .env directly
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  COUNTRIES_MCP_URL="https://${COUNTRIES_HOST}/mcp"
  mkdir -p certs cfg
fi

if [[ "${UNATTENDED_WORKER}" != "true" ]]; then
# ------------------------------------------------------------------------------
# Stage 1: Create Projects, Link Billing, Enable APIs & Configure IAM
# ------------------------------------------------------------------------------
stage "Stage 1: Projects, Billing, APIs & Service Accounts"

for PROJ in "${HUB_PROJECT_ID}" "${APIGEE_PROJECT_ID}"; do
  P_STATE="$(gcloud projects describe "${PROJ}" --format='value(lifecycleState)' 2>/dev/null || echo 'MISSING')"
  if [[ "${P_STATE}" == "ACTIVE" ]]; then
    skip "Project '${PROJ}' already exists (ACTIVE)."
  elif [[ "${P_STATE}" == "DELETE_REQUESTED" ]]; then
    err "Project '${PROJ}' is in DELETE_REQUESTED state. Run 'gcloud projects undelete ${PROJ}' or re-run ./deploy.sh --reconfigure with a new project ID."
    exit 1
  else
    info "Creating project '${PROJ}'..."
    gcloud projects create "${PROJ}"
    ok "Created project '${PROJ}'."
  fi

  BILLING_JSON=""
  for _ in 1 2 3; do
    BILLING_JSON="$(gcloud billing projects describe "${PROJ}" --format=json 2>/dev/null || true)"
    [[ -n "${BILLING_JSON}" ]] && break
    sleep 2
  done
  CUR_BILLING="$(echo "${BILLING_JSON}" | jq -r '.billingAccountName // empty' 2>/dev/null || true)"
  CUR_BILLING_ENABLED="$(echo "${BILLING_JSON}" | jq -r '.billingEnabled // false' 2>/dev/null || echo "false")"
  if [[ "${CUR_BILLING}" == "billingAccounts/${BILLING_ACCOUNT_ID}" && ( "${CUR_BILLING_ENABLED}" == "True" || "${CUR_BILLING_ENABLED}" == "true" ) ]]; then
    skip "Billing account '${BILLING_ACCOUNT_ID}' already linked to '${PROJ}'."
  else
    info "Linking billing account '${BILLING_ACCOUNT_ID}' to '${PROJ}'..."
    gcloud billing projects link "${PROJ}" --billing-account="${BILLING_ACCOUNT_ID}" >/dev/null
    ok "Linked billing account '${BILLING_ACCOUNT_ID}' to '${PROJ}'."
  fi
done

HUB_PROJECT_NUMBER="$(gcloud projects describe "${HUB_PROJECT_ID}" --format='value(projectNumber)')"
APIGEE_PROJECT_NUMBER="$(gcloud projects describe "${APIGEE_PROJECT_ID}" --format='value(projectNumber)')"
ORG_ID="$(gcloud projects get-ancestors "${HUB_PROJECT_ID}" --format=json | jq -r '[.[] | select(.type=="organization") | .id][0] // empty')"

if [[ -n "${ORG_ID}" ]]; then
  TRUST_DOMAIN="agents.global.org-${ORG_ID}.system.id.goog"
else
  TRUST_DOMAIN="agents.global.proj-${HUB_PROJECT_NUMBER}.system.id.goog"
fi

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
ensure_project_apis "${HUB_PROJECT_ID}" "${HUB_APIS[@]}"

if [[ -n "${ORG_ID}" ]]; then
  for CONSTRAINT in \
    discoveryengine.managed.disableCustomMcpServerConnector \
    iam.managed.disableAccessPolicyBinding; do
    ensure_org_policy_unenforced "${HUB_PROJECT_ID}" "${HUB_PROJECT_NUMBER}" "${CONSTRAINT}"
  done
  if [[ "${ORG_POLICY_JUST_OVERRIDDEN}" == "true" ]]; then
    WORKER_EXTRA_ARGS+=("--org-policy-updated")
  fi
fi

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
ensure_project_apis "${APIGEE_PROJECT_ID}" "${APIGEE_APIS[@]}"

APIGEE_SERVICE_AGENT="service-${APIGEE_PROJECT_NUMBER}@gcp-sa-apigee.iam.gserviceaccount.com"

APIGEE_SA_INITIALIZED=false
if project_has_member_any_role "${APIGEE_PROJECT_ID}" "serviceAccount:${APIGEE_SERVICE_AGENT}"; then
  APIGEE_SA_INITIALIZED=true
elif gcloud iam service-accounts get-iam-policy "sa-apigee-invoker@${APIGEE_PROJECT_ID}.iam.gserviceaccount.com" \
  --project="${APIGEE_PROJECT_ID}" --format=json 2>/dev/null \
  | jq -e --arg m "serviceAccount:${APIGEE_SERVICE_AGENT}" '.bindings[]?.members[]? | select(. == $m)' >/dev/null 2>&1; then
  APIGEE_SA_INITIALIZED=true
fi

if [[ "${APIGEE_SA_INITIALIZED}" != "true" ]]; then
  info "Initializing Google-managed service agents on '${APIGEE_PROJECT_ID}'..."
  for SVC in apigee.googleapis.com cloudkms.googleapis.com compute.googleapis.com cloudbuild.googleapis.com; do
    gcloud beta services identity create --service="${SVC}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1 || true
  done
  rm -f "cfg/.iam_${APIGEE_PROJECT_ID}.json"
else
  skip "Google-managed service agents already initialized on '${APIGEE_PROJECT_ID}'."
fi

if ! project_has_member_any_role "${HUB_PROJECT_ID}" "serviceAccount:service-${HUB_PROJECT_NUMBER}@gcp-sa-discoveryengine.iam.gserviceaccount.com"; then
  info "Initializing Google-managed service agents on '${HUB_PROJECT_ID}'..."
  for SVC in networkservices.googleapis.com discoveryengine.googleapis.com compute.googleapis.com cloudbuild.googleapis.com; do
    gcloud beta services identity create --service="${SVC}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1 || true
  done
  rm -f "cfg/.iam_${HUB_PROJECT_ID}.json"
else
  skip "Google-managed service agents already initialized on '${HUB_PROJECT_ID}'."
fi

ensure_project_iam_roles "${HUB_PROJECT_ID}" \
  "serviceAccount:service-${HUB_PROJECT_NUMBER}@gcp-sa-discoveryengine.iam.gserviceaccount.com" \
  roles/discoveryengine.serviceAgent

# Grant Cloud Build source-deploy permissions to Default Compute SAs (when iam.automaticIamGrantsForDefaultServiceAccounts is enforced)
for PAIR in "${HUB_PROJECT_ID}:${HUB_PROJECT_NUMBER}" "${APIGEE_PROJECT_ID}:${APIGEE_PROJECT_NUMBER}"; do
  IFS=":" read -r P_ID P_NUM <<< "${PAIR}"
  ensure_project_iam_roles "${P_ID}" "serviceAccount:${P_NUM}-compute@developer.gserviceaccount.com" \
    roles/storage.admin \
    roles/artifactregistry.writer \
    roles/logging.logWriter \
    roles/cloudbuild.builds.builder
done

for SA_SPEC in \
  "${APIGEE_PROJECT_ID}:sa-mcp-countries:Country Facts Internal MCP Runtime SA" \
  "${APIGEE_PROJECT_ID}:sa-apigee-invoker:Apigee X Southbound Cloud Run Invoker SA" \
  "${HUB_PROJECT_ID}:sa-mcp-verifier:In-VPC MCP Verifier SA"; do
  IFS=":" read -r P_ID SA_NAME SA_DESC <<< "${SA_SPEC}"
  if gcloud iam service-accounts describe "${SA_NAME}@${P_ID}.iam.gserviceaccount.com" --project="${P_ID}" >/dev/null 2>&1; then
    skip "Service account '${SA_NAME}@${P_ID}.iam.gserviceaccount.com' already exists."
  else
    info "Creating service account '${SA_NAME}@${P_ID}.iam.gserviceaccount.com'..."
    gcloud iam service-accounts create "${SA_NAME}" --display-name="${SA_DESC}" --project="${P_ID}"
  fi
done

ensure_sa_iam_roles "${APIGEE_PROJECT_ID}" \
  "sa-apigee-invoker@${APIGEE_PROJECT_ID}.iam.gserviceaccount.com" \
  "serviceAccount:${APIGEE_SERVICE_AGENT}" \
  roles/iam.serviceAccountUser \
  roles/iam.serviceAccountTokenCreator

# ------------------------------------------------------------------------------
# Stage 2: Guided Web OAuth 2.0 Client Collection (Browser-Only Security Control)
# ------------------------------------------------------------------------------
stage "Stage 2: Google Auth Platform Web OAuth 2.0 Client"

if [[ -z "${OAUTH_CLIENT_ID}" || -z "${OAUTH_CLIENT_SECRET}" ]]; then
  echo -e "${YELLOW}Google Cloud restricts 3LO Web OAuth 2.0 client creation (*.apps.googleusercontent.com)"
  echo -e "to the Google Cloud Console for anti-phishing security (60-second one-time step):${NC}"
  echo ""
  echo "  1. Open Google Auth Platform for ${HUB_PROJECT_ID}:"
  echo "     https://console.cloud.google.com/auth/clients?project=${HUB_PROJECT_ID}"
  echo "  2. Configure the OAuth consent screen first (required on a new project):"
  echo "     Click 'Get started' -> enter an App name & support email -> Audience: 'Internal'"
  echo "     -> enter a Contact email -> agree & click 'Create'."
  echo "  3. Open Clients to create a new OAuth client:"
  echo "     In the left-hand menu, click 'Clients', then click '+ Create client' at the top."
  echo "  4. Select Application type: 'Web application' (and enter any Name)."
  echo "  5. Under 'Authorized redirect URIs', click '+ Add URI' and paste:"
  echo "     https://vertexaisearch.cloud.google.com/oauth-redirect"
  echo "  6. Click 'Create', then copy the Client ID and Client secret from the"
  echo "     'OAuth client created' dialog and paste them below."
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
  skip "OAuth 2.0 Client already configured in ${ENV_FILE} (${OAUTH_CLIENT_ID})."
fi

if [[ "${BACKGROUND_MODE}" == "true" ]]; then
  nohup "${SCRIPT_DIR}/deploy.sh" --unattended-worker ${WORKER_EXTRA_ARGS[@]+"${WORKER_EXTRA_ARGS[@]}"} > "${LOG_FILE}" 2>&1 </dev/null &
  BG_PID=$!
  echo "${BG_PID}" > "${PID_FILE}"
  echo ""
  ok "Detached Stages 3-10 into background worker (PID ${BG_PID})."
  info "Follow live logs anytime (Ctrl+C stops watching without stopping the job):"
  echo "    tail -f ${LOG_FILE}"
  info "Check worker status anytime:"
  echo "    ps -p \$(cat ${PID_FILE})"
  DETACHED_CLEANLY=true
  exit 0
fi
else
  HUB_PROJECT_NUMBER="$(gcloud projects describe "${HUB_PROJECT_ID}" --format='value(projectNumber)')"
  APIGEE_PROJECT_NUMBER="$(gcloud projects describe "${APIGEE_PROJECT_ID}" --format='value(projectNumber)')"
  ORG_ID="$(gcloud projects get-ancestors "${HUB_PROJECT_ID}" --format=json | jq -r '[.[] | select(.type=="organization") | .id][0] // empty')"
  if [[ -n "${ORG_ID}" ]]; then
    TRUST_DOMAIN="agents.global.org-${ORG_ID}.system.id.goog"
  else
    TRUST_DOMAIN="agents.global.proj-${HUB_PROJECT_NUMBER}.system.id.goog"
  fi
  APIGEE_SERVICE_AGENT="service-${APIGEE_PROJECT_NUMBER}@gcp-sa-apigee.iam.gserviceaccount.com"
fi

# ------------------------------------------------------------------------------
# Stage 3: Cloud Identity (global), Free Trial License & Gemini Enterprise App
# ------------------------------------------------------------------------------
stage "Stage 3: Cloud Identity (${GE_LOCATION}), Trial License & App (${GE_APP_ID})"

CURRENT_IDP="$(curl -s \
  -H "Authorization: Bearer $(get_token)" \
  -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
  "https://${GE_LOCATION}-discoveryengine.googleapis.com/v1alpha/projects/${HUB_PROJECT_ID}/locations/${GE_LOCATION}/aclConfig" \
  | jq -r '.idpConfig.idpType // empty' 2>/dev/null || true)"

if [[ "${CURRENT_IDP}" != "GSUITE" ]]; then
  info "Assigning Cloud Identity / Google Workspace (GSUITE) as Identity Provider in '${GE_LOCATION}'..."
  curl -s -X PATCH \
    "https://${GE_LOCATION}-discoveryengine.googleapis.com/v1alpha/projects/${HUB_PROJECT_ID}/locations/${GE_LOCATION}/aclConfig" \
    -H "Authorization: Bearer $(get_token)" \
    -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"projects/${HUB_PROJECT_ID}/locations/${GE_LOCATION}/aclConfig\",
      \"idpConfig\": {\"idpType\": \"GSUITE\"}
    }" >/dev/null
  ok "Configured '${GE_LOCATION}' aclConfig -> idpType: GSUITE."
else
  skip "Cloud Identity ('${GE_LOCATION}' aclConfig -> GSUITE) already configured."
fi

EXISTING_LICENSES="$(curl -s \
  -H "Authorization: Bearer $(get_token)" \
  -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
  "https://${GE_LOCATION}-discoveryengine.googleapis.com/v1alpha/projects/${HUB_PROJECT_ID}/locations/${GE_LOCATION}/licenseConfigs" \
  | jq -r '[.licenseConfigs[]? | select(.state == "ACTIVE" or .state == "NOT_STARTED")] | length' 2>/dev/null || echo "0")"

if [[ "${EXISTING_LICENSES}" == "0" ]]; then
  info "No Gemini Enterprise license found on ${HUB_PROJECT_ID}; provisioning 50-seat 30-day free trial license..."
  read -r YEAR MONTH DAY <<< "$(python3 -c 'from datetime import datetime, timezone, timedelta; d = datetime.now(timezone.utc) + timedelta(days=1); print(d.year, d.month, d.day)')"

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
      \"freeTrial\": true
    }")"

  if echo "${TRIAL_RESP}" | jq -e '.name' >/dev/null 2>&1; then
    LIC_NAME="$(echo "${TRIAL_RESP}" | jq -r '.name')"
    LIC_STATE="$(echo "${TRIAL_RESP}" | jq -r '.state // "UNKNOWN"')"
    ok "Provisioned Gemini Enterprise 30-day free trial (${LIC_NAME}, state=${LIC_STATE})."
    if [[ "${LIC_STATE}" == "NOT_STARTED" ]]; then
      info "Note: REST-created trials start at next UTC day (${YEAR}-${MONTH}-${DAY}); to activate seats immediately today, open Cloud Console -> Gemini Enterprise -> Subscriptions (https://console.cloud.google.com/gemini-enterprise?project=${HUB_PROJECT_ID})."
    fi
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
    warn "Continuing (if your billing account already used its 1-time trial, enable a subscription in Cloud Console -> Gemini Enterprise -> Subscriptions: https://console.cloud.google.com/gemini-enterprise?project=${HUB_PROJECT_ID})."
  fi
else
  skip "Gemini Enterprise license config (${EXISTING_LICENSES} found) already present on '${HUB_PROJECT_ID}'."
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
  ok "Created Discovery Engine DataStore 'ge-init-store'."
else
  skip "Discovery Engine DataStore 'ge-init-store' already exists."
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
  skip "Gemini Enterprise app '${GE_APP_ID}' already exists."
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
  ok "Generated Enterprise Private Root CA (certs/ca.crt)."
else
  skip "Enterprise Private Root CA (certs/ca.crt) already exists."
fi

if gcloud certificate-manager trust-configs describe tc-mcp-corp-internal --location="${REGION}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  skip "Certificate Manager TrustConfig 'tc-mcp-corp-internal' already exists."
else
  info "Creating Certificate Manager TrustConfig 'tc-mcp-corp-internal'..."
  gcloud certificate-manager trust-configs create tc-mcp-corp-internal \
    --location="${REGION}" \
    --trust-store="trust-anchors=certs/ca.crt" \
    --project="${HUB_PROJECT_ID}"
fi

if gcloud compute networks describe vpc-mcp-internal --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  skip "Hub VPC 'vpc-mcp-internal' already exists."
else
  info "Creating Hub VPC 'vpc-mcp-internal'..."
  gcloud compute networks create vpc-mcp-internal --subnet-mode=custom --project="${HUB_PROJECT_ID}"
fi

if gcloud compute networks subnets describe subnet-ilb-backend --region="${REGION}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  skip "Subnet 'subnet-ilb-backend' already exists."
else
  gcloud compute networks subnets create subnet-ilb-backend \
    --network=vpc-mcp-internal --region="${REGION}" --range=10.10.1.0/24 \
    --enable-private-ip-google-access --project="${HUB_PROJECT_ID}"
fi

if gcloud compute networks subnets describe subnet-ilb-proxy --region="${REGION}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  skip "Proxy-only subnet 'subnet-ilb-proxy' already exists."
else
  gcloud compute networks subnets create subnet-ilb-proxy \
    --network=vpc-mcp-internal --region="${REGION}" --range=10.10.2.0/24 \
    --purpose=REGIONAL_MANAGED_PROXY --role=ACTIVE --project="${HUB_PROJECT_ID}"
fi

if gcloud compute networks subnets describe subnet-agw-psc --region="${REGION}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  skip "Agent Gateway PSC subnet 'subnet-agw-psc' already exists."
else
  gcloud compute networks subnets create subnet-agw-psc \
    --network=vpc-mcp-internal --region="${REGION}" --range=10.10.3.0/28 \
    --enable-private-ip-google-access --project="${HUB_PROJECT_ID}"
fi

if gcloud compute network-attachments describe na-agw-mcp-internal --region="${REGION}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  skip "PSC Network Attachment 'na-agw-mcp-internal' already exists."
else
  gcloud compute network-attachments create na-agw-mcp-internal \
    --region="${REGION}" --subnets=subnet-agw-psc \
    --connection-preference=ACCEPT_AUTOMATIC --project="${HUB_PROJECT_ID}"
fi

if gcloud dns managed-zones describe zone-corp-internal --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  skip "Cloud DNS private zone 'zone-corp-internal' already exists."
else
  gcloud dns managed-zones create zone-corp-internal \
    --dns-name="corp.internal." --description="Private DNS zone for internal MCP services" \
    --visibility=private --networks=vpc-mcp-internal --project="${HUB_PROJECT_ID}"
fi

AGW_SA="service-${HUB_PROJECT_NUMBER}@gcp-sa-agentgateway.iam.gserviceaccount.com"
if ! project_has_member_any_role "${HUB_PROJECT_ID}" "serviceAccount:${AGW_SA}"; then
  if ! gcloud projects add-iam-policy-binding "${HUB_PROJECT_ID}" \
    --member="serviceAccount:${AGW_SA}" \
    --role="roles/agentgateway.serviceAgent" --condition=None --quiet >/dev/null 2>&1; then
    info "Initializing Agent Gateway service agent (${AGW_SA}) on blank project..."
    BOOT_OP="$(curl -s -X POST \
      "https://networkservices.googleapis.com/v1/projects/${HUB_PROJECT_ID}/locations/${REGION}/agentGateways?agentGatewayId=agw-sa-init" \
      -H "Authorization: Bearer $(get_token)" \
      -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
      -H "Content-Type: application/json" \
      -d '{"protocols":["MCP"],"googleManaged":{"governedAccessPath":"AGENT_TO_ANYWHERE"}}' | jq -r '.name // empty' 2>/dev/null || true)"
    if [[ -n "${BOOT_OP}" ]]; then
      for _ in {1..30}; do
        [[ "$(curl -s -H "Authorization: Bearer $(get_token)" -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" "https://networkservices.googleapis.com/v1/${BOOT_OP}" | jq -r '.done // false' 2>/dev/null)" == "true" ]] && break
        sleep 5
      done
      DEL_BOOT="$(curl -s -X DELETE \
        "https://networkservices.googleapis.com/v1/projects/${HUB_PROJECT_ID}/locations/${REGION}/agentGateways/agw-sa-init" \
        -H "Authorization: Bearer $(get_token)" \
        -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" | jq -r '.name // empty' 2>/dev/null || true)"
      [[ -n "${DEL_BOOT}" ]] && sleep 5
    fi
  fi
  rm -f "cfg/.iam_${HUB_PROJECT_ID}.json"
fi

IAM_ROLE_GRANTED=false
ensure_project_iam_roles "${HUB_PROJECT_ID}" "serviceAccount:${AGW_SA}" \
  roles/agentgateway.serviceAgent \
  roles/compute.networkViewer \
  roles/compute.networkAdmin \
  roles/dns.reader \
  roles/certificatemanager.viewer

PSC_NA_URI="projects/${HUB_PROJECT_NUMBER}/regions/${REGION}/networkAttachments/na-agw-mcp-internal"
TRUST_CONFIG_URI="projects/${HUB_PROJECT_NUMBER}/locations/${REGION}/trustConfigs/tc-mcp-corp-internal"
ACT_URI="projects/${HUB_PROJECT_NUMBER}/locations/${REGION}/agentConnectivityTemplates/act-vpc-mcp-internal"
AGW_NAME="agw-vpc-${REGION}-ata"
AGW_URI="projects/${HUB_PROJECT_ID}/locations/${REGION}/agentGateways/${AGW_NAME}"

ACT_GET="https://networkservices.googleapis.com/v1/projects/${HUB_PROJECT_ID}/locations/${REGION}/agentConnectivityTemplates/act-vpc-mcp-internal"
if [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(get_token)" -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" "${ACT_GET}")" == "200" ]]; then
  skip "AgentConnectivityTemplate 'act-vpc-mcp-internal' already exists."
else
  if [[ "${IAM_ROLE_GRANTED}" == "true" ]]; then
    info "Waiting 60s for newly granted Agent Gateway Service Agent IAM roles to propagate..."
    sleep 60
  fi
  info "Creating AgentConnectivityTemplate 'act-vpc-mcp-internal'..."
  networkservices_post_with_iam_retry \
    "https://networkservices.googleapis.com/v1/projects/${HUB_PROJECT_ID}/locations/${REGION}/agentConnectivityTemplates?agentConnectivityTemplateId=act-vpc-mcp-internal" \
    "{
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
    }" \
    "AgentConnectivityTemplate 'act-vpc-mcp-internal'" 5
  ok "Created AgentConnectivityTemplate 'act-vpc-mcp-internal'."
fi

AGW_GET="https://networkservices.googleapis.com/v1/projects/${HUB_PROJECT_ID}/locations/${REGION}/agentGateways/${AGW_NAME}"
if [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(get_token)" -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" "${AGW_GET}")" == "200" ]]; then
  skip "Hub AgentGateway '${AGW_NAME}' already exists."
else
  info "Creating Hub AgentGateway '${AGW_NAME}'..."
  networkservices_post_with_iam_retry \
    "https://networkservices.googleapis.com/v1/projects/${HUB_PROJECT_ID}/locations/${REGION}/agentGateways?agentGatewayId=${AGW_NAME}" \
    "{
      \"protocols\": [\"MCP\"],
      \"googleManaged\": {\"governedAccessPath\": \"AGENT_TO_ANYWHERE\"},
      \"agentConnectivityTemplate\": \"${ACT_URI}\",
      \"registries\": [\"//agentregistry.googleapis.com/projects/${HUB_PROJECT_ID}/locations/${REGION}\"]
    }" \
    "AgentGateway '${AGW_NAME}'" 10
  ok "Created Hub AgentGateway '${AGW_NAME}'."
fi

if gcloud service-extensions authz-extensions describe agw-authz-ext-iap-v2 --location="${REGION}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  skip "Service Extension AuthzExtension 'agw-authz-ext-iap-v2' already exists."
else
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
if [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(get_token)" -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" "${AUTHZ_GET}")" == "200" ]]; then
  skip "AuthzPolicy '${AGW_NAME}-authz-policy-iap' already exists."
else
  AUTHZ_RESP="$(curl -s -X POST \
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
    }")"
  wait_gcp_op "https://networksecurity.googleapis.com/v1alpha1" "${AUTHZ_RESP}" "AuthzPolicy '${AGW_NAME}-authz-policy-iap'" 5
  ok "Created AuthzPolicy '${AGW_NAME}-authz-policy-iap'."
fi

UAP_GET="https://iam.googleapis.com/v3/projects/${HUB_PROJECT_ID}/locations/global/accessPolicies/agent-gateway-allow-policy"
if [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(get_token)" -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" "${UAP_GET}")" == "200" ]]; then
  skip "IAM v3 AccessPolicy 'agent-gateway-allow-policy' already exists."
else
  info "Creating IAM v3 Universal Access Policy 'agent-gateway-allow-policy'..."
  UAP_RESP="$(curl -s -X POST \
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
    }")"
  wait_gcp_op "https://iam.googleapis.com/v3" "${UAP_RESP}" "IAM v3 AccessPolicy 'agent-gateway-allow-policy'" 3
  ok "Created IAM v3 AccessPolicy 'agent-gateway-allow-policy'."
fi

BIND_GET="https://iam.googleapis.com/v3/projects/${HUB_PROJECT_ID}/locations/global/policyBindings/agent-gateway-allow-binding"
if [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(get_token)" -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" "${BIND_GET}")" == "200" ]]; then
  skip "IAM v3 PolicyBinding 'agent-gateway-allow-binding' already exists."
else
  info "Binding IAM v3 Universal Access Policy to project '${HUB_PROJECT_ID}'..."
  if [[ -n "${ORG_ID}" ]]; then
    ensure_org_policy_unenforced "${HUB_PROJECT_ID}" "${HUB_PROJECT_NUMBER}" "iam.managed.disableAccessPolicyBinding"
  fi
  for bind_attempt in {1..10}; do
    BIND_RESP="$(curl -s -X POST \
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
      }")"
    if echo "${BIND_RESP}" | jq -e '.error' >/dev/null 2>&1; then
      BIND_ERR="$(echo "${BIND_RESP}" | jq -c '.error')"
      if [[ "${bind_attempt}" -lt 10 && ( "${BIND_ERR}" == *"POLICY_NOT_FOUND"* || "${BIND_ERR}" == *"not yet available"* || "${BIND_ERR}" == *"does not exist"* || "${BIND_ERR}" == *"ORG_POLICY"* || "${BIND_ERR}" == *"disableAccessPolicyBinding"* ) ]]; then
        warn "IAM v3 PolicyBinding prerequisite/org-policy still propagating globally (attempt ${bind_attempt}/10); retrying in 15s..."
        interruptible_sleep 15
        continue
      fi
      err "Failed starting IAM v3 PolicyBinding 'agent-gateway-allow-binding': ${BIND_ERR}"
      exit 1
    fi
    BIND_OP="$(echo "${BIND_RESP}" | jq -r '.name // empty' 2>/dev/null || true)"
    if [[ -z "${BIND_OP}" || "${BIND_OP}" != */operations/* ]]; then
      break
    fi
    BIND_RETRY=false
    while true; do
      BIND_POLL="$(curl -s -H "Authorization: Bearer $(get_token)" -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" "https://iam.googleapis.com/v3/${BIND_OP}")"
      if [[ "$(echo "${BIND_POLL}" | jq -r '.done // false' 2>/dev/null || echo "false")" == "true" ]]; then
        if echo "${BIND_POLL}" | jq -e '.error' >/dev/null 2>&1; then
          BIND_OP_ERR="$(echo "${BIND_POLL}" | jq -c '.error')"
          if [[ "${bind_attempt}" -lt 10 && ( "${BIND_OP_ERR}" == *"POLICY_NOT_FOUND"* || "${BIND_OP_ERR}" == *"not yet available"* || "${BIND_OP_ERR}" == *"does not exist"* || "${BIND_OP_ERR}" == *"ORG_POLICY"* || "${BIND_OP_ERR}" == *"disableAccessPolicyBinding"* ) ]]; then
            warn "IAM v3 PolicyBinding prerequisite/org-policy still propagating globally (attempt ${bind_attempt}/10); retrying in 15s..."
            BIND_RETRY=true
            break
          fi
          err "IAM v3 PolicyBinding 'agent-gateway-allow-binding' failed: ${BIND_OP_ERR}"
          exit 1
        fi
        break
      fi
      interruptible_sleep 3
    done
    if [[ "${BIND_RETRY}" == "true" ]]; then
      interruptible_sleep 15
      continue
    fi
    break
  done
  ok "Created IAM v3 PolicyBinding 'agent-gateway-allow-binding'."
fi

AGW_NUMBER_URI="projects/${HUB_PROJECT_NUMBER}/locations/${REGION}/agentGateways/${AGW_NAME}"
CUR_ENG_AGW="$(curl -s \
  -H "Authorization: Bearer $(get_token)" \
  -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
  "https://${GE_LOCATION}-discoveryengine.googleapis.com/v1/projects/${HUB_PROJECT_ID}/locations/${GE_LOCATION}/collections/default_collection/engines/${GE_APP_ID}" \
  | jq -r '.agentGatewaySetting.defaultEgressAgentGateway.name // empty' 2>/dev/null || true)"
if [[ "${CUR_ENG_AGW}" == *"/agentGateways/${AGW_NAME}" ]]; then
  skip "Engine '${GE_APP_ID}' defaultEgressAgentGateway already bound to '${AGW_NAME}'."
else
  info "Binding '${GE_APP_ID}' defaultEgressAgentGateway to '${AGW_NAME}'..."
  for eng_agw_attempt in {1..6}; do
    ENG_AGW_RESP="$(curl -s -X PATCH \
      "https://${GE_LOCATION}-discoveryengine.googleapis.com/v1/projects/${HUB_PROJECT_ID}/locations/${GE_LOCATION}/collections/default_collection/engines/${GE_APP_ID}?updateMask=agentGatewaySetting.defaultEgressAgentGateway.name" \
      -H "Authorization: Bearer $(get_token)" \
      -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
      -H "Content-Type: application/json" \
      -d "{\"agentGatewaySetting\": {\"defaultEgressAgentGateway\": {\"name\": \"${AGW_NUMBER_URI}\"}}}")"
    if echo "${ENG_AGW_RESP}" | jq -e '.error' >/dev/null 2>&1; then
      ENG_AGW_ERR="$(echo "${ENG_AGW_RESP}" | jq -c '.error')"
      if [[ "${eng_agw_attempt}" -lt 6 && ( "${ENG_AGW_ERR}" == *"PERMISSION_DENIED"* || "${ENG_AGW_ERR}" == *"denied"* ) ]]; then
        warn "Discovery Engine Service Agent IAM still propagating (attempt ${eng_agw_attempt}/6); retrying in 15s..."
        interruptible_sleep 15
        continue
      fi
      err "Failed binding defaultEgressAgentGateway on '${GE_APP_ID}': ${ENG_AGW_ERR}"
      exit 1
    fi
    break
  done
  ok "Bound '${GE_APP_ID}' defaultEgressAgentGateway to '${AGW_NAME}'."
fi

# ------------------------------------------------------------------------------
# Stage 5: Deploy Internal Cloud Run MCP Server (mcp-countries-poc)
# ------------------------------------------------------------------------------
stage "Stage 5: Deploy Internal Cloud Run MCP Server (${APIGEE_PROJECT_ID})"

EXISTING_CR_URL="$(gcloud run services describe mcp-countries-poc --region="${REGION}" --project="${APIGEE_PROJECT_ID}" --format='value(status.url)' 2>/dev/null || true)"
if [[ -n "${EXISTING_CR_URL}" && "${REBUILD_MCP}" != "true" ]]; then
  CLOUD_RUN_URL="${EXISTING_CR_URL}"
  save_env
  skip "Cloud Run MCP service 'mcp-countries-poc' already deployed (${CLOUD_RUN_URL}). Pass --rebuild-mcp to rebuild."
else
  info "Deploying Cloud Run MCP service 'mcp-countries-poc' from source..."
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
  CLOUD_RUN_URL="$(gcloud run services describe mcp-countries-poc --region="${REGION}" --project="${APIGEE_PROJECT_ID}" --format='value(status.url)')"
  save_env
  ok "Cloud Run MCP server deployed: ${CLOUD_RUN_URL}"
fi

ensure_run_invoker "${APIGEE_PROJECT_ID}" "${REGION}" "mcp-countries-poc" \
  "serviceAccount:sa-apigee-invoker@${APIGEE_PROJECT_ID}.iam.gserviceaccount.com"

# ------------------------------------------------------------------------------
# Stage 6: Provision Apigee X (EVALUATION, disableVpcPeering=true), KMS & Truststore
# ------------------------------------------------------------------------------
stage "Stage 6: Apigee X EVALUATION Org, KMS, Runtime Instance & Truststore"

if gcloud kms keyrings describe "apigee-keyring-${REGION}" --location="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
  skip "Cloud KMS KeyRing 'apigee-keyring-${REGION}' already exists."
else
  gcloud kms keyrings create "apigee-keyring-${REGION}" --location="${REGION}" --project="${APIGEE_PROJECT_ID}"
fi

if gcloud kms keys describe apigee-disk-key --keyring="apigee-keyring-${REGION}" --location="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
  skip "Cloud KMS CryptoKey 'apigee-disk-key' already exists."
else
  gcloud kms keys create apigee-disk-key --keyring="apigee-keyring-${REGION}" --location="${REGION}" --purpose=encryption --project="${APIGEE_PROJECT_ID}"
fi

KMS_KEY_ID="projects/${APIGEE_PROJECT_ID}/locations/${REGION}/keyRings/apigee-keyring-${REGION}/cryptoKeys/apigee-disk-key"
ensure_kms_iam_role "${APIGEE_PROJECT_ID}" "${REGION}" "apigee-keyring-${REGION}" "apigee-disk-key" \
  "serviceAccount:${APIGEE_SERVICE_AGENT}" "roles/cloudkms.cryptoKeyEncrypterDecrypter"

ORG_STATE=""
for _ in 1 2 3; do
  ORG_BODY="$(curl -s -H "Authorization: Bearer $(get_token)" "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}")"
  ORG_STATE="$(echo "${ORG_BODY}" | jq -r '.state // empty' 2>/dev/null || true)"
  ORG_ERR_CODE="$(echo "${ORG_BODY}" | jq -r '.error.code // empty' 2>/dev/null || true)"
  [[ -n "${ORG_STATE}" || "${ORG_ERR_CODE}" == "404" || "${ORG_ERR_CODE}" == "403" ]] && break
  sleep 3
done

if [[ "${ORG_STATE}" == "ACTIVE" ]]; then
  skip "Apigee X organization '${APIGEE_PROJECT_ID}' already exists (ACTIVE)."
elif [[ -n "${ORG_STATE}" ]]; then
  info "Apigee X organization '${APIGEE_PROJECT_ID}' is currently ${ORG_STATE}; waiting until ACTIVE..."
  while [[ "$(curl -s -H "Authorization: Bearer $(get_token)" "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}" | jq -r '.state // ""' 2>/dev/null)" != "ACTIVE" ]]; do
    interruptible_sleep 10
  done
  wait_apigee_idle
  ok "Apigee X organization '${APIGEE_PROJECT_ID}' is now ACTIVE."
else
  info "Creating Apigee X EVALUATION organization '${APIGEE_PROJECT_ID}' (disableVpcPeering=true)..."
  apigee_post_and_wait \
    "https://apigee.googleapis.com/v1/organizations?parent=projects/${APIGEE_PROJECT_ID}" \
    "{
      \"name\": \"${APIGEE_PROJECT_ID}\",
      \"displayName\": \"Apigee X Internal MCP Organization\",
      \"analyticsRegion\": \"${REGION}\",
      \"runtimeType\": \"CLOUD\",
      \"billingType\": \"EVALUATION\",
      \"disableVpcPeering\": true
    }" \
    "Apigee organization '${APIGEE_PROJECT_ID}'" 10
  ok "Created Apigee X organization '${APIGEE_PROJECT_ID}'."
fi

if [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(get_token)" "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/environments/eval-mcp")" == "200" ]]; then
  skip "Apigee environment 'eval-mcp' already exists."
else
  info "Creating Apigee environment 'eval-mcp'..."
  apigee_post_and_wait \
    "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/environments" \
    '{"name": "eval-mcp", "displayName": "Internal MCP Evaluation Env", "deploymentType": "PROXY", "apiProxyType": "PROGRAMMABLE"}' \
    "Apigee environment 'eval-mcp'" 5
  ok "Created Apigee environment 'eval-mcp'."
fi

if [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(get_token)" "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/envgroups/internal-mcp-group")" == "200" ]]; then
  skip "Apigee environment group 'internal-mcp-group' already exists."
else
  info "Creating Apigee environment group 'internal-mcp-group' (${COUNTRIES_HOST})..."
  apigee_post_and_wait \
    "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/envgroups" \
    "{\"name\": \"internal-mcp-group\", \"hostnames\": [\"${COUNTRIES_HOST}\"]}" \
    "Apigee envgroup 'internal-mcp-group'" 5
  ok "Created Apigee environment group 'internal-mcp-group'."
fi

EG_ATTACHED="$(curl -s -H "Authorization: Bearer $(get_token)" \
  "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/envgroups/internal-mcp-group/attachments" \
  | jq -r '[.environmentGroupAttachments[]? | select(.environment == "eval-mcp")] | length' 2>/dev/null || echo "0")"
if [[ "${EG_ATTACHED}" != "0" ]]; then
  skip "Environment 'eval-mcp' already attached to 'internal-mcp-group'."
else
  info "Attaching environment 'eval-mcp' to 'internal-mcp-group'..."
  apigee_post_and_wait \
    "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/envgroups/internal-mcp-group/attachments" \
    '{"environment": "eval-mcp"}' \
    "EnvGroup attachment 'eval-mcp'" 5
  ok "Attached environment 'eval-mcp' to 'internal-mcp-group'."
fi

INST_URL="https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/instances/apigee-${REGION}"
INST_STATE="$(curl -s -H "Authorization: Bearer $(get_token)" "${INST_URL}" | jq -r '.state // "MISSING"' 2>/dev/null || echo "MISSING")"
if [[ "${INST_STATE}" == "ACTIVE" ]]; then
  skip "Apigee X runtime instance 'apigee-${REGION}' already exists (ACTIVE)."
elif [[ "${INST_STATE}" == "CREATING" ]]; then
  info "Apigee X runtime instance 'apigee-${REGION}' is already CREATING; resuming wait until ACTIVE..."
  ELAPSED=0
  while [[ "$(curl -s -H "Authorization: Bearer $(get_token)" "${INST_URL}" | jq -r '.state // ""' 2>/dev/null)" != "ACTIVE" ]]; do
    if [[ -t 1 ]]; then
      printf "\r  ... Waiting for CREATING Apigee runtime (%dm %02ds elapsed)" $((ELAPSED/60)) $((ELAPSED%60))
    elif (( ELAPSED % 60 == 0 )); then
      echo "  ... Waiting for CREATING Apigee runtime ($((ELAPSED/60))m elapsed)"
    fi
    interruptible_sleep 30
    ELAPSED=$((ELAPSED+30))
  done
  [[ -t 1 ]] && echo ""
  ok "Apigee X runtime instance 'apigee-${REGION}' is now ACTIVE."
else
  info "Provisioning Apigee X Runtime Instance 'apigee-${REGION}' (~20-25 minutes; single-tenant runtime)..."
  apigee_post_and_wait \
    "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/instances" \
    "{
      \"name\": \"apigee-${REGION}\",
      \"location\": \"${REGION}\",
      \"diskEncryptionKeyName\": \"${KMS_KEY_ID}\",
      \"consumerAcceptList\": [\"${HUB_PROJECT_ID}\", \"${APIGEE_PROJECT_ID}\"]
    }" \
    "Apigee runtime instance 'apigee-${REGION}'" 30
  ok "Apigee X runtime instance 'apigee-${REGION}' is now ACTIVE."
fi

ATTACHED="$(curl -s -H "Authorization: Bearer $(get_token)" "${INST_URL}/attachments" | jq -r '[.attachments[]? | select(.environment == "eval-mcp")] | length' 2>/dev/null || echo "0")"
if [[ "${ATTACHED}" != "0" ]]; then
  skip "Environment 'eval-mcp' already attached to runtime instance 'apigee-${REGION}'."
else
  info "Attaching environment 'eval-mcp' to runtime instance 'apigee-${REGION}'..."
  apigee_post_and_wait "${INST_URL}/attachments" '{"environment": "eval-mcp"}' "Instance attachment 'eval-mcp'" 10
  ok "Attached environment 'eval-mcp' to runtime instance 'apigee-${REGION}'."
fi

APIGEE_NB_SERVICE_ATTACHMENT="$(curl -s -H "Authorization: Bearer $(get_token)" "${INST_URL}" | jq -r '.serviceAttachment // empty' 2>/dev/null || true)"
if [[ -z "${APIGEE_NB_SERVICE_ATTACHMENT}" ]]; then
  err "Could not read .serviceAttachment from ${INST_URL}"
  exit 1
fi
save_env
ok "Apigee Northbound PSC Service Attachment: ${APIGEE_NB_SERVICE_ATTACHMENT}"

if [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(get_token)" "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/environments/eval-mcp/keystores/mcp-ca-truststore")" == "200" ]]; then
  skip "Apigee truststore 'mcp-ca-truststore' already exists."
else
  info "Creating Apigee truststore 'mcp-ca-truststore'..."
  KS_RESP="$(curl -s -X POST "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/environments/eval-mcp/keystores" \
    -H "Authorization: Bearer $(get_token)" -H "Content-Type: application/json" \
    -d '{"name": "mcp-ca-truststore"}')"
  if echo "${KS_RESP}" | jq -e '.error' >/dev/null 2>&1; then
    err "Failed creating Apigee truststore 'mcp-ca-truststore': $(echo "${KS_RESP}" | jq -c '.error')"
    exit 1
  fi
  ok "Created Apigee truststore 'mcp-ca-truststore'."
fi

if [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(get_token)" "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/environments/eval-mcp/keystores/mcp-ca-truststore/aliases/mcp-root-ca")" == "200" ]]; then
  skip "Apigee truststore alias 'mcp-root-ca' already uploaded."
else
  info "Uploading Root CA alias 'mcp-root-ca' to 'mcp-ca-truststore'..."
  ALIAS_RESP="$(curl -s -X POST "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/environments/eval-mcp/keystores/mcp-ca-truststore/aliases?alias=mcp-root-ca&format=keycertfile" \
    -H "Authorization: Bearer $(get_token)" -F "file=@certs/ca.crt")"
  if echo "${ALIAS_RESP}" | jq -e '.error' >/dev/null 2>&1; then
    err "Failed uploading alias 'mcp-root-ca': $(echo "${ALIAS_RESP}" | jq -c '.error')"
    exit 1
  fi
  ok "Uploaded Root CA alias 'mcp-root-ca' to 'mcp-ca-truststore'."
fi

if [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(get_token)" "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/environments/eval-mcp/references/mcp-ca-truststore-ref")" == "200" ]]; then
  skip "Apigee truststore reference 'mcp-ca-truststore-ref' already exists."
else
  info "Creating Apigee truststore reference 'mcp-ca-truststore-ref'..."
  REF_RESP="$(curl -s -X POST "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/environments/eval-mcp/references" \
    -H "Authorization: Bearer $(get_token)" -H "Content-Type: application/json" \
    -d '{"name": "mcp-ca-truststore-ref", "resourceType": "KeyStore", "refers": "mcp-ca-truststore"}')"
  if echo "${REF_RESP}" | jq -e '.error' >/dev/null 2>&1; then
    err "Failed creating Apigee truststore reference 'mcp-ca-truststore-ref': $(echo "${REF_RESP}" | jq -c '.error')"
    exit 1
  fi
  ok "Created Apigee truststore reference 'mcp-ca-truststore-ref'."
fi

# ------------------------------------------------------------------------------
# Stage 7: Southbound Producer VPC, Internal HTTPS ALB, PSC & Two-Pass SAN TLS
# ------------------------------------------------------------------------------
stage "Stage 7: Southbound Producer VPC, PSC & Two-Pass EA_HOST SAN TLS"

if gcloud compute networks describe vpc-apigee-mcp --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
  skip "Southbound VPC 'vpc-apigee-mcp' already exists."
else
  gcloud compute networks create vpc-apigee-mcp --subnet-mode=custom --project="${APIGEE_PROJECT_ID}"
fi
if gcloud compute networks subnets describe subnet-apigee-mcp-backend --region="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
  skip "Subnet 'subnet-apigee-mcp-backend' already exists."
else
  gcloud compute networks subnets create subnet-apigee-mcp-backend \
    --network=vpc-apigee-mcp --region="${REGION}" --range=10.30.1.0/24 \
    --enable-private-ip-google-access --project="${APIGEE_PROJECT_ID}"
fi
if gcloud compute networks subnets describe subnet-apigee-mcp-proxy --region="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
  skip "Proxy-only subnet 'subnet-apigee-mcp-proxy' already exists."
else
  gcloud compute networks subnets create subnet-apigee-mcp-proxy \
    --network=vpc-apigee-mcp --region="${REGION}" --purpose=REGIONAL_MANAGED_PROXY \
    --role=ACTIVE --range=10.30.2.0/24 --project="${APIGEE_PROJECT_ID}"
fi
if gcloud compute networks subnets describe subnet-apigee-mcp-psc-nat --region="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
  skip "PSC NAT subnet 'subnet-apigee-mcp-psc-nat' already exists."
else
  gcloud compute networks subnets create subnet-apigee-mcp-psc-nat \
    --network=vpc-apigee-mcp --region="${REGION}" --purpose=PRIVATE_SERVICE_CONNECT \
    --range=10.30.3.0/24 --project="${APIGEE_PROJECT_ID}"
fi
if gcloud compute addresses describe ip-ilb-mcp-countries --region="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
  skip "Southbound ILB IP 'ip-ilb-mcp-countries' (${SB_ILB_IP}) already exists."
else
  gcloud compute addresses create ip-ilb-mcp-countries \
    --region="${REGION}" --subnet=subnet-apigee-mcp-backend \
    --addresses="${SB_ILB_IP}" --project="${APIGEE_PROJECT_ID}"
fi

ensure_sb_csr() {
  if [[ ! -f certs/mcp-countries-sb.key ]]; then
    openssl genrsa -out certs/mcp-countries-sb.key 2048
  fi
  if [[ ! -f certs/mcp-countries-sb.csr ]]; then
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
  fi
}

if gcloud compute ssl-certificates describe cert-mcp-countries-sb-v1 --region="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
  skip "Southbound Pass-1 SSL certificate 'cert-mcp-countries-sb-v1' already exists."
else
  ensure_sb_csr
  openssl x509 -req -in certs/mcp-countries-sb.csr -CA certs/ca.crt -CAkey certs/ca.key -CAcreateserial \
    -out certs/mcp-countries-sb-init.crt -days 825 -sha256 -extensions v3_req -extfile certs/countries-sb-init.cnf
  gcloud compute ssl-certificates create cert-mcp-countries-sb-v1 \
    --certificate=certs/mcp-countries-sb-init.crt --private-key=certs/mcp-countries-sb.key \
    --region="${REGION}" --project="${APIGEE_PROJECT_ID}"
fi
if gcloud compute network-endpoint-groups describe neg-mcp-countries-poc --region="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
  skip "Serverless NEG 'neg-mcp-countries-poc' already exists."
else
  gcloud compute network-endpoint-groups create neg-mcp-countries-poc \
    --region="${REGION}" --network-endpoint-type=serverless \
    --cloud-run-service=mcp-countries-poc --project="${APIGEE_PROJECT_ID}"
fi
if gcloud compute backend-services describe bs-mcp-countries-poc --region="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
  skip "Southbound BackendService 'bs-mcp-countries-poc' already exists."
else
  gcloud compute backend-services create bs-mcp-countries-poc \
    --load-balancing-scheme=INTERNAL_MANAGED --protocol=HTTP \
    --region="${REGION}" --project="${APIGEE_PROJECT_ID}"
  gcloud compute backend-services add-backend bs-mcp-countries-poc \
    --region="${REGION}" --network-endpoint-group=neg-mcp-countries-poc \
    --network-endpoint-group-region="${REGION}" --project="${APIGEE_PROJECT_ID}"
fi
if gcloud compute url-maps describe um-mcp-countries-poc --region="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
  skip "Southbound URL Map 'um-mcp-countries-poc' already exists."
else
  gcloud compute url-maps create um-mcp-countries-poc \
    --default-service=bs-mcp-countries-poc --region="${REGION}" --project="${APIGEE_PROJECT_ID}"
fi
if gcloud compute target-https-proxies describe tp-mcp-countries-poc --region="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
  skip "Southbound TargetHTTPSProxy 'tp-mcp-countries-poc' already exists."
else
  gcloud compute target-https-proxies create tp-mcp-countries-poc \
    --url-map=um-mcp-countries-poc --ssl-certificates=cert-mcp-countries-sb-v1 \
    --region="${REGION}" --project="${APIGEE_PROJECT_ID}"
fi
if gcloud compute forwarding-rules describe fr-mcp-countries-poc --region="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
  skip "Southbound ForwardingRule 'fr-mcp-countries-poc' already exists."
else
  gcloud compute forwarding-rules create fr-mcp-countries-poc \
    --load-balancing-scheme=INTERNAL_MANAGED --network=vpc-apigee-mcp \
    --subnet=subnet-apigee-mcp-backend --address=ip-ilb-mcp-countries --ports=443 \
    --region="${REGION}" --target-https-proxy=tp-mcp-countries-poc \
    --target-https-proxy-region="${REGION}" --project="${APIGEE_PROJECT_ID}"
fi
if gcloud compute service-attachments describe sa-psc-mcp-countries --region="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
  skip "Southbound PSC ServiceAttachment 'sa-psc-mcp-countries' already exists."
else
  gcloud compute service-attachments create sa-psc-mcp-countries \
    --region="${REGION}" --producer-forwarding-rule=fr-mcp-countries-poc \
    --connection-preference=ACCEPT_AUTOMATIC --nat-subnets=subnet-apigee-mcp-psc-nat \
    --project="${APIGEE_PROJECT_ID}"
fi

SB_SERVICE_ATTACHMENT="projects/${APIGEE_PROJECT_ID}/regions/${REGION}/serviceAttachments/sa-psc-mcp-countries"
EA_URL="https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/endpointAttachments/ea-mcp-countries"
EA_STATE="$(curl -s -H "Authorization: Bearer $(get_token)" "${EA_URL}" | jq -r '.state // "MISSING"' 2>/dev/null || echo "MISSING")"
if [[ "${EA_STATE}" == "ACTIVE" ]]; then
  skip "Apigee Southbound EndpointAttachment 'ea-mcp-countries' already exists (ACTIVE)."
elif [[ "${EA_STATE}" == "CREATING" ]]; then
  info "Apigee Southbound EndpointAttachment 'ea-mcp-countries' is CREATING; waiting until ACTIVE..."
  while [[ "$(curl -s -H "Authorization: Bearer $(get_token)" "${EA_URL}" | jq -r '.state // ""' 2>/dev/null)" != "ACTIVE" ]]; do
    interruptible_sleep 10
  done
else
  info "Creating Apigee Southbound EndpointAttachment 'ea-mcp-countries'..."
  apigee_post_and_wait \
    "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/endpointAttachments?endpointAttachmentId=ea-mcp-countries" \
    "{\"location\": \"${REGION}\", \"serviceAttachment\": \"${SB_SERVICE_ATTACHMENT}\"}" \
    "Southbound EndpointAttachment 'ea-mcp-countries'" 10
fi

EA_HOST=""
for _ in {1..15}; do
  EA_HOST="$(curl -s -H "Authorization: Bearer $(get_token)" "${EA_URL}" | jq -r '.host // empty' 2>/dev/null || true)"
  [[ -n "${EA_HOST}" ]] && break
  interruptible_sleep 4
done
if [[ -z "${EA_HOST}" ]]; then
  err "Could not retrieve .host from EndpointAttachment ${EA_URL}"
  exit 1
fi
save_env
ok "Apigee Southbound EndpointAttachment IP (EA_HOST): ${EA_HOST}"

CURRENT_SB_CERT="$(gcloud compute target-https-proxies describe tp-mcp-countries-poc --region="${REGION}" --project="${APIGEE_PROJECT_ID}" --format='value(sslCertificates)' 2>/dev/null || true)"
if gcloud compute ssl-certificates describe cert-mcp-countries-sb-v2 --region="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1 && [[ "${CURRENT_SB_CERT}" == *"cert-mcp-countries-sb-v2"* ]]; then
  skip "Southbound TargetHTTPSProxy already using Pass-2 SAN certificate 'cert-mcp-countries-sb-v2' (IP:${EA_HOST})."
else
  if ! gcloud compute ssl-certificates describe cert-mcp-countries-sb-v2 --region="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null 2>&1; then
    ensure_sb_csr
    cat > certs/countries-sb-ext.cnf <<EOF
[v3_req]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:${COUNTRIES_HOST},IP:${SB_ILB_IP},IP:${HUB_APIGEE_ILB_IP},IP:${EA_HOST}
EOF
    openssl x509 -req -in certs/mcp-countries-sb.csr -CA certs/ca.crt -CAkey certs/ca.key -CAcreateserial \
      -out certs/mcp-countries-sb.crt -days 825 -sha256 -extensions v3_req -extfile certs/countries-sb-ext.cnf
    gcloud compute ssl-certificates create cert-mcp-countries-sb-v2 \
      --certificate=certs/mcp-countries-sb.crt --private-key=certs/mcp-countries-sb.key \
      --region="${REGION}" --project="${APIGEE_PROJECT_ID}"
  fi
  gcloud compute target-https-proxies update tp-mcp-countries-poc \
    --ssl-certificates=cert-mcp-countries-sb-v2 --region="${REGION}" --project="${APIGEE_PROJECT_ID}" >/dev/null
  ok "Updated Southbound Target HTTPS Proxy with Pass-2 SAN certificate (IP:${EA_HOST})."
fi

# ------------------------------------------------------------------------------
# Stage 8: Render, Package & Deploy Apigee X Proxy (country-facts-mcp)
# ------------------------------------------------------------------------------
stage "Stage 8: Deploy Apigee X Proxy 'country-facts-mcp'"

DEPLOYED_REV="$(curl -s -H "Authorization: Bearer $(get_token)" \
  "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/environments/eval-mcp/apis/country-facts-mcp/deployments" \
  | jq -r '.deployments[0].revision // empty' 2>/dev/null || true)"

if [[ -n "${DEPLOYED_REV}" && "${REDEPLOY_PROXY}" != "true" ]]; then
  skip "Apigee proxy 'country-facts-mcp' (revision ${DEPLOYED_REV}) already deployed to 'eval-mcp'. Pass --redeploy-proxy to update."
else
  sed \
    -e "s|__EA_HOST__|${EA_HOST}|g" \
    -e "s|__CLOUD_RUN_URL__|${CLOUD_RUN_URL}|g" \
    apigee_bundles/country-facts-mcp/apiproxy/targets/default.xml.tmpl \
    > apigee_bundles/country-facts-mcp/apiproxy/targets/default.xml

  rm -f country-facts-mcp.zip
  (cd apigee_bundles/country-facts-mcp && zip -qr ../../country-facts-mcp.zip apiproxy -x "*.tmpl" -x "*/.DS_Store" -x ".DS_Store")

  IMPORT_RESP="$(curl -s -X POST \
    "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/apis?action=import&name=country-facts-mcp" \
    -H "Authorization: Bearer $(get_token)" \
    -F "file=@country-facts-mcp.zip")"
  REV="$(echo "${IMPORT_RESP}" | jq -r '.revision // empty' 2>/dev/null || true)"
  if [[ -z "${REV}" || "${REV}" == "null" ]]; then
    err "Failed importing Apigee proxy 'country-facts-mcp': ${IMPORT_RESP}"
    exit 1
  fi

  DEPLOY_RESP="$(curl -s -X POST \
    "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/environments/eval-mcp/apis/country-facts-mcp/revisions/${REV}/deployments?override=true&serviceAccount=sa-apigee-invoker@${APIGEE_PROJECT_ID}.iam.gserviceaccount.com" \
    -H "Authorization: Bearer $(get_token)")"
  if echo "${DEPLOY_RESP}" | jq -e '.error' >/dev/null 2>&1; then
    err "Failed deploying Apigee proxy 'country-facts-mcp': ${DEPLOY_RESP}"
    exit 1
  fi
  for _ in {1..36}; do
    REV_STATE="$(curl -s -H "Authorization: Bearer $(get_token)" \
      "https://apigee.googleapis.com/v1/organizations/${APIGEE_PROJECT_ID}/environments/eval-mcp/apis/country-facts-mcp/revisions/${REV}/deployments" \
      | jq -r '.state // empty' 2>/dev/null || true)"
    [[ "${REV_STATE}" == "READY" ]] && break
    interruptible_sleep 5
  done
  ok "Deployed Apigee proxy 'country-facts-mcp' revision ${REV} as sa-apigee-invoker (state=${REV_STATE:-READY})."
fi

# ------------------------------------------------------------------------------
# Stage 9: Northbound Consumer PSC NEG, Hub ALB, DNS & Agent Registry
# ------------------------------------------------------------------------------
stage "Stage 9: Northbound PSC NEG, Hub HTTPS ALB, DNS & Agent Registry"

if gcloud compute addresses describe ip-ilb-apigee-countries --region="${REGION}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  skip "Hub Northbound ILB IP 'ip-ilb-apigee-countries' (${HUB_APIGEE_ILB_IP}) already exists."
else
  gcloud compute addresses create ip-ilb-apigee-countries \
    --region="${REGION}" --subnet=subnet-ilb-backend \
    --addresses="${HUB_APIGEE_ILB_IP}" --project="${HUB_PROJECT_ID}"
fi

if gcloud compute ssl-certificates describe cert-mcp-countries-hub --region="${REGION}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  skip "Hub Northbound SSL certificate 'cert-mcp-countries-hub' already exists."
else
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
  gcloud compute ssl-certificates create cert-mcp-countries-hub \
    --certificate=certs/mcp-countries.crt --private-key=certs/mcp-countries.key \
    --region="${REGION}" --project="${HUB_PROJECT_ID}"
fi
if gcloud compute network-endpoint-groups describe neg-psc-apigee-countries --region="${REGION}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  skip "Northbound PSC NEG 'neg-psc-apigee-countries' already exists."
else
  gcloud compute network-endpoint-groups create neg-psc-apigee-countries \
    --network-endpoint-type=private-service-connect \
    --psc-target-service="${APIGEE_NB_SERVICE_ATTACHMENT}" \
    --network=vpc-mcp-internal --subnet=subnet-ilb-backend \
    --region="${REGION}" --project="${HUB_PROJECT_ID}"
fi
if gcloud compute backend-services describe bs-apigee-countries --region="${REGION}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  skip "Northbound BackendService 'bs-apigee-countries' already exists."
else
  gcloud compute backend-services create bs-apigee-countries \
    --load-balancing-scheme=INTERNAL_MANAGED --protocol=HTTPS \
    --region="${REGION}" --project="${HUB_PROJECT_ID}"
  gcloud compute backend-services add-backend bs-apigee-countries \
    --network-endpoint-group=neg-psc-apigee-countries \
    --network-endpoint-group-region="${REGION}" --region="${REGION}" --project="${HUB_PROJECT_ID}"
fi
if gcloud compute url-maps describe um-apigee-countries --region="${REGION}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  skip "Northbound URL Map 'um-apigee-countries' already exists."
else
  gcloud compute url-maps create um-apigee-countries \
    --default-service=bs-apigee-countries --region="${REGION}" --project="${HUB_PROJECT_ID}"
fi
if gcloud compute target-https-proxies describe tp-apigee-countries --region="${REGION}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  skip "Northbound TargetHTTPSProxy 'tp-apigee-countries' already exists."
else
  gcloud compute target-https-proxies create tp-apigee-countries \
    --url-map=um-apigee-countries --ssl-certificates=cert-mcp-countries-hub \
    --region="${REGION}" --project="${HUB_PROJECT_ID}"
fi
if gcloud compute forwarding-rules describe fr-apigee-countries --region="${REGION}" --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  skip "Northbound ForwardingRule 'fr-apigee-countries' already exists."
else
  gcloud compute forwarding-rules create fr-apigee-countries \
    --load-balancing-scheme=INTERNAL_MANAGED --network=vpc-mcp-internal \
    --subnet=subnet-ilb-backend --address=ip-ilb-apigee-countries --ports=443 \
    --region="${REGION}" --target-https-proxy=tp-apigee-countries \
    --target-https-proxy-region="${REGION}" --project="${HUB_PROJECT_ID}"
fi
if gcloud dns record-sets describe "${COUNTRIES_HOST}." --type=A --zone=zone-corp-internal --project="${HUB_PROJECT_ID}" >/dev/null 2>&1; then
  skip "Cloud DNS A record '${COUNTRIES_HOST}.' -> ${HUB_APIGEE_ILB_IP} already exists."
else
  gcloud dns record-sets create "${COUNTRIES_HOST}." \
    --zone=zone-corp-internal --type=A --ttl=60 \
    --rrdatas="${HUB_APIGEE_ILB_IP}" --project="${HUB_PROJECT_ID}"
fi

AR_SVC_URL="https://agentregistry.googleapis.com/v1/projects/${HUB_PROJECT_ID}/locations/${REGION}/services/mcp-countries-poc"
if [[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(get_token)" -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" "${AR_SVC_URL}")" == "200" ]]; then
  skip "Agent Registry service 'mcp-countries-poc' already registered."
else
  info "Registering 'mcp-countries-poc' in Hub Agent Registry..."
  TOOLSPEC_JSON="$(cat cfg/toolspec_countries.json)"
  AR_RESP="$(curl -s -X POST \
    "https://agentregistry.googleapis.com/v1/projects/${HUB_PROJECT_ID}/locations/${REGION}/services?serviceId=mcp-countries-poc" \
    -H "Authorization: Bearer $(get_token)" \
    -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
    -H "Content-Type: application/json" \
    -d "{
      \"displayName\": \"Country Facts MCP Server (Apigee X + PSC + OAuth2)\",
      \"description\": \"Internal Country Facts StreamableHTTP MCP server hosted in ${APIGEE_PROJECT_ID} behind Apigee X over Northbound and Southbound PSC (${COUNTRIES_MCP_URL}).\",
      \"interfaces\": [{\"protocolBinding\": \"JSONRPC\", \"url\": \"${COUNTRIES_MCP_URL}\"}],
      \"mcpServerSpec\": {\"type\": \"TOOL_SPEC\", \"content\": ${TOOLSPEC_JSON}}
    }")"
  wait_gcp_op "https://agentregistry.googleapis.com/v1" "${AR_RESP}" "Agent Registry service 'mcp-countries-poc'" 3
  ok "Registered 'mcp-countries-poc' in Hub Agent Registry."
fi

MCP_COUNTRIES_REGISTRY_URI=""
for _ in {1..15}; do
  MCP_COUNTRIES_REGISTRY_URI="$(curl -s \
    -H "Authorization: Bearer $(get_token)" \
    -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
    "https://agentregistry.googleapis.com/v1alpha/projects/${HUB_PROJECT_ID}/locations/${REGION}/mcpServers" \
    | jq -r --arg url "${COUNTRIES_MCP_URL}" '.mcpServers[]? | select(.interfaces[]?.url == $url) | .name' 2>/dev/null | head -n 1)"
  [[ -n "${MCP_COUNTRIES_REGISTRY_URI}" ]] && break
  sleep 4
done
if [[ -z "${MCP_COUNTRIES_REGISTRY_URI}" ]]; then
  err "Could not resolve Agent Registry mcpServer URI for ${COUNTRIES_MCP_URL}"
  exit 1
fi
save_env
ok "Agent Registry MCP Server URI: ${MCP_COUNTRIES_REGISTRY_URI}"

# ------------------------------------------------------------------------------
# Stage 10: Connect Gemini Enterprise REGISTRY_MCP OAuth Data Connector & Verify
# ------------------------------------------------------------------------------
stage "Stage 10: Connect Gemini Enterprise & Run Verification"

if [[ -n "${ORG_ID}" ]]; then
  ensure_org_policy_unenforced "${HUB_PROJECT_ID}" "${HUB_PROJECT_NUMBER}" "discoveryengine.managed.disableCustomMcpServerConnector"
fi

COLLECTION_DISPLAY_NAME="mcp-countries-apigee-collection"
DISCOVERED_COLL="$(curl -s \
  "https://${GE_LOCATION}-discoveryengine.googleapis.com/v1alpha/projects/${HUB_PROJECT_ID}/locations/${GE_LOCATION}/collections" \
  -H "Authorization: Bearer $(get_token)" \
  -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
  | jq -r --arg dn "${COLLECTION_DISPLAY_NAME}" --arg saved "${GE_COUNTRIES_COLLECTION_ID:-}" \
    '.collections[]? | select(.displayName == $dn or ($saved != "" and (.name | endswith("/" + $saved)))) | .name | split("/") | last' 2>/dev/null | head -n 1)"

if [[ -n "${DISCOVERED_COLL}" ]]; then
  GE_COUNTRIES_COLLECTION_ID="${DISCOVERED_COLL}"
  save_env
  skip "Discovery Engine collection '${GE_COUNTRIES_COLLECTION_ID}' already exists."
else
  if [[ "${ORG_POLICY_JUST_OVERRIDDEN}" == "true" && "${SECONDS}" -lt 45 ]]; then
    WAIT_PROP=$((45 - SECONDS))
    info "Waiting ${WAIT_PROP}s for newly disabled 'discoveryengine.managed.disableCustomMcpServerConnector' Organization Policy to propagate..."
    interruptible_sleep "${WAIT_PROP}"
  fi

  for dc_attempt in {1..12}; do
    COLLECTION_ID="mcp-countries-apigee-collection-$(date +%s)"
    info "Creating Gemini Enterprise REGISTRY_MCP data connector collection '${COLLECTION_ID}'..."
    SETUP_DC_RESP="$(curl -s -X POST \
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
      }")"
    if echo "${SETUP_DC_RESP}" | jq -e '.error' >/dev/null 2>&1; then
      DC_ERR="$(echo "${SETUP_DC_RESP}" | jq -c '.error')"
      if [[ "${dc_attempt}" -lt 12 && ( "${DC_ERR}" == *"CUSTOM_ORG_POLICY_VIOLATION"* || "${DC_ERR}" == *"disableCustomMcpServerConnector"* ) ]]; then
        if [[ -n "${ORG_ID}" ]]; then
          ensure_org_policy_unenforced "${HUB_PROJECT_ID}" "${HUB_PROJECT_NUMBER}" "discoveryengine.managed.disableCustomMcpServerConnector"
        fi
        warn "Org policy override 'discoveryengine.managed.disableCustomMcpServerConnector' still propagating to Discovery Engine (attempt ${dc_attempt}/12); retrying in 15s..."
        interruptible_sleep 15
        continue
      fi
      err "setUpDataConnector failed: ${DC_ERR}"
      exit 1
    fi
    break
  done

  GE_COUNTRIES_COLLECTION_ID=""
  for _ in {1..60}; do
    GE_COUNTRIES_COLLECTION_ID="$(curl -s \
      "https://${GE_LOCATION}-discoveryengine.googleapis.com/v1alpha/projects/${HUB_PROJECT_ID}/locations/${GE_LOCATION}/collections" \
      -H "Authorization: Bearer $(get_token)" \
      -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" \
      | jq -r --arg cid "${COLLECTION_ID}" '.collections[]? | select(.name | endswith("/" + $cid)) | .name | split("/") | last' 2>/dev/null || true)"
    [[ -n "${GE_COUNTRIES_COLLECTION_ID}" ]] && break
    interruptible_sleep 5
  done
  if [[ -z "${GE_COUNTRIES_COLLECTION_ID}" ]]; then
    err "Timed out waiting for Discovery Engine collection '${COLLECTION_ID}' to appear."
    exit 1
  fi
  save_env
fi

DC_URL="https://discoveryengine.googleapis.com/v1alpha/projects/${HUB_PROJECT_ID}/locations/global/collections/${GE_COUNTRIES_COLLECTION_ID}/dataConnector"
DC_CONFIGURED="$(curl -s -H "Authorization: Bearer $(get_token)" -H "X-Goog-User-Project: ${HUB_PROJECT_ID}" "${DC_URL}" \
  | jq -r --arg reg "${MCP_COUNTRIES_REGISTRY_URI}" \
    'if (.actionConfig.isActionConfigured == true and .actionConfig.actionParams.registry_mcp_server_name == $reg) then "true" else "false" end' 2>/dev/null || echo "false")"

if [[ "${DC_CONFIGURED}" == "true" ]]; then
  skip "Gemini Enterprise REGISTRY_MCP connector '${GE_COUNTRIES_COLLECTION_ID}' actionConfig already active."
else
  info "Activating Gemini Enterprise REGISTRY_MCP connector actionConfig (${GE_COUNTRIES_COLLECTION_ID})..."
  for patch_attempt in {1..12}; do
    DC_PATCH_RESP="$(curl -s -X PATCH \
      "${DC_URL}?updateMask=actionConfig" \
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
      }")"
    if echo "${DC_PATCH_RESP}" | jq -e '.error' >/dev/null 2>&1; then
      PATCH_ERR="$(echo "${DC_PATCH_RESP}" | jq -c '.error')"
      if [[ "${patch_attempt}" -lt 12 && ( "${PATCH_ERR}" == *"CUSTOM_ORG_POLICY_VIOLATION"* || "${PATCH_ERR}" == *"disableCustomMcpServerConnector"* ) ]]; then
        warn "Org policy override still propagating to Discovery Engine PATCH (attempt ${patch_attempt}/12); retrying in 15s..."
        interruptible_sleep 15
        continue
      fi
      err "Failed activating dataConnector actionConfig: ${PATCH_ERR}"
      exit 1
    fi
    break
  done
  ok "Activated Gemini Enterprise REGISTRY_MCP connector (${GE_COUNTRIES_COLLECTION_ID})."
fi

if [[ "${REBUILD_VERIFIER}" == "true" ]]; then
  ./verify.sh --rebuild
else
  ./verify.sh
fi
