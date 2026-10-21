#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
SCENARIO_DIR="${REPO_DIR}/scenarios/mlflow-agent-observability"
AGENT_RBAC_MANIFEST="${SCENARIO_DIR}/manifests/agent/rbac.yaml"
AGENT_JOB_TEMPLATE="${SCENARIO_DIR}/manifests/agent/job.template.yaml"
AGENT_SCRIPT="${SCENARIO_DIR}/agent_demo/run_demo.py"
AGENT_NAMESPACE="agent-demo"
JOB_NAME="maas-mlflow-agent-demo-$(date +%s)-${RANDOM}"
AGENT_DEMO_TIMEOUT_SECONDS="${AGENT_DEMO_TIMEOUT_SECONDS:-900}"
AGENT_DEMO_RATE_LIMIT_REQUESTS="${AGENT_DEMO_RATE_LIMIT_REQUESTS:-12}"
RHOAI_APPLICATIONS_NAMESPACE="redhat-ods-applications"
CLUSTER_DOMAIN=""
MAAS_HOST=""
API_KEY=""
API_KEY_ID=""
ROUTER_CA_FILE=""

cleanup() {
  if [[ -n "${API_KEY_ID:-}" && -n "${MAAS_HOST:-}" ]]; then
    curl -sS -k -X DELETE \
      -H "Authorization: Bearer $(oc whoami -t)" \
      "https://${MAAS_HOST}/maas-api/v1/api-keys/${API_KEY_ID}" \
      >/dev/null 2>&1 || true
  fi

  oc delete job "${JOB_NAME}" -n "${AGENT_NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1 || true
  oc delete secret maas-agent-demo-key -n "${AGENT_NAMESPACE}" --ignore-not-found=true >/dev/null 2>&1 || true
  rm -f "${ROUTER_CA_FILE:-}"
  unset API_KEY API_KEY_ID API_KEY_RESPONSE
}
trap cleanup EXIT

if ! command -v oc >/dev/null 2>&1; then
  echo "Error: the OpenShift CLI (oc) is required." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required." >&2
  exit 1
fi

if ! oc whoami >/dev/null 2>&1; then
  echo "Error: no authenticated OpenShift CLI session. Run oc login first." >&2
  exit 1
fi

if ! [[ "${AGENT_DEMO_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: AGENT_DEMO_TIMEOUT_SECONDS must be a positive integer." >&2
  exit 1
fi

if ! [[ "${AGENT_DEMO_RATE_LIMIT_REQUESTS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: AGENT_DEMO_RATE_LIMIT_REQUESTS must be a positive integer." >&2
  exit 1
fi

MLFLOW_READY="$(oc get mlflow mlflow \
  -n "${RHOAI_APPLICATIONS_NAMESPACE}" \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')"
if [[ "${MLFLOW_READY}" != "True" ]]; then
  echo "Error: MLflow is not available. Run 'make deploy-mlflow' first." >&2
  exit 1
fi

if ! oc get maasmodelref facebook-opt-125m-simulated -n llm >/dev/null 2>&1; then
  echo "Error: the simulator model is not deployed. Run 'make deploy-model' first." >&2
  exit 1
fi

MODEL_PHASE="$(oc get maasmodelref facebook-opt-125m-simulated \
  -n llm \
  -o jsonpath='{.status.phase}')"
if [[ "${MODEL_PHASE}" != "Ready" ]]; then
  echo "Error: the simulator MaaS model reference is not Ready. Run 'make deploy-model' first." >&2
  exit 1
fi

MAAS_MODEL_ID="$(oc get maasmodelref facebook-opt-125m-simulated \
  -n llm \
  -o jsonpath='{.status.resolvedModelAlias}')"
if [[ -z "${MAAS_MODEL_ID}" ]]; then
  echo "Error: the simulator MaaS model ID is not available. Run 'make deploy-model' first." >&2
  exit 1
fi

CLUSTER_DOMAIN="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
if [[ -z "${CLUSTER_DOMAIN}" ]]; then
  echo "Error: the cluster ingress domain could not be determined." >&2
  exit 1
fi

MAAS_HOST="${MAAS_HOSTNAME:-maas.${CLUSTER_DOMAIN}}"
ROUTER_CA_FILE="$(mktemp)"

MAAS_HEALTH_CODE="$(curl -sS -k --connect-timeout 10 --max-time 30 \
  -o /dev/null \
  -w '%{http_code}' \
  "https://${MAAS_HOST}/maas-api/health")"
if [[ "${MAAS_HEALTH_CODE}" != "200" ]]; then
  echo "Error: the MaaS health endpoint returned HTTP ${MAAS_HEALTH_CODE}." >&2
  exit 1
fi

echo "Preparing the MLflow agent demo..."
oc apply -f "${AGENT_RBAC_MANIFEST}"

oc get secret router-ca \
  -n openshift-ingress-operator \
  -o jsonpath='{.data.tls\.crt}' \
  | base64 --decode >"${ROUTER_CA_FILE}"
oc create configmap maas-agent-router-ca \
  -n "${AGENT_NAMESPACE}" \
  --from-file=ca-bundle.crt="${ROUTER_CA_FILE}" \
  --dry-run=client \
  -o yaml \
  | oc apply -f -

oc create configmap maas-mlflow-agent-demo \
  -n "${AGENT_NAMESPACE}" \
  --from-file=run_demo.py="${AGENT_SCRIPT}" \
  --dry-run=client \
  -o yaml \
  | oc apply -f -

echo "Creating a temporary MaaS API key..."
API_KEY_RESPONSE="$(curl -sS -k --connect-timeout 10 --max-time 30 \
  -X POST \
  -H "Authorization: Bearer $(oc whoami -t)" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"agent-demo-$(date +%s)\",\"description\":\"Temporary MLflow agent demo key\",\"expiresIn\":\"1h\",\"subscription\":\"simulator-free\"}" \
  "https://${MAAS_HOST}/maas-api/v1/api-keys")"
API_KEY="$(printf '%s' "${API_KEY_RESPONSE}" | jq -r '.key // empty')"
API_KEY_ID="$(printf '%s' "${API_KEY_RESPONSE}" | jq -r '.id // empty')"
if [[ -z "${API_KEY}" || -z "${API_KEY_ID}" ]]; then
  API_KEY_ERROR="$(printf '%s' "${API_KEY_RESPONSE}" \
    | jq -r '.message // .error // "MaaS did not return an API key or ID."')"
  echo "Error: MaaS API-key creation failed: ${API_KEY_ERROR}" >&2
  exit 1
fi

oc create secret generic maas-agent-demo-key \
  -n "${AGENT_NAMESPACE}" \
  --from-literal=maas-api-key="${API_KEY}" \
  --dry-run=client \
  -o yaml \
  | oc apply -f -

oc process \
  -f "${AGENT_JOB_TEMPLATE}" \
  -p JOB_NAME="${JOB_NAME}" \
  -p MAAS_BASE_URL="https://${MAAS_HOST}" \
  -p MAAS_MODEL_ID="${MAAS_MODEL_ID}" \
  -p RATE_LIMIT_REQUESTS="${AGENT_DEMO_RATE_LIMIT_REQUESTS}" \
  -p TIMEOUT_SECONDS="${AGENT_DEMO_TIMEOUT_SECONDS}" \
  | oc create -f - -n "${AGENT_NAMESPACE}"

echo "Created Job: ${JOB_NAME}"
echo "Running the MLflow agent demo Job..."
DEADLINE=$((SECONDS + AGENT_DEMO_TIMEOUT_SECONDS))
MISSING_JOB_ATTEMPTS=0
while (( SECONDS < DEADLINE )); do
  JOB_JSON="$(oc get job "${JOB_NAME}" \
    -n "${AGENT_NAMESPACE}" \
    --ignore-not-found=true \
    -o json)"

  if [[ -z "${JOB_JSON}" || "${JOB_JSON}" == "null" ]]; then
    ((MISSING_JOB_ATTEMPTS+=1))
    if (( MISSING_JOB_ATTEMPTS >= 6 )); then
      echo "Error: the MLflow agent demo Job is missing after creation: ${JOB_NAME}." >&2
      oc get events -n "${AGENT_NAMESPACE}" \
        --sort-by=.lastTimestamp \
        -o custom-columns=LAST:.lastTimestamp,TYPE:.type,REASON:.reason,MESSAGE:.message \
        | tail -30 >&2 || true
      exit 1
    fi
    sleep 5
    continue
  fi

  MISSING_JOB_ATTEMPTS=0
  COMPLETE="$(printf '%s' "${JOB_JSON}" | jq -r '.status.conditions[]? | select(.type == "Complete") | .status // empty')"
  FAILED="$(printf '%s' "${JOB_JSON}" | jq -r '.status.conditions[]? | select(.type == "Failed") | .status // empty')"

  if [[ "${FAILED}" == "True" ]]; then
    echo "Error: the MLflow agent demo Job failed." >&2
    oc logs "job/${JOB_NAME}" -n "${AGENT_NAMESPACE}" >&2 || true
    exit 1
  fi

  if [[ "${COMPLETE}" == "True" ]]; then
    oc logs "job/${JOB_NAME}" -n "${AGENT_NAMESPACE}"
    MLFLOW_URL="$(oc get mlflow mlflow \
      -n "${RHOAI_APPLICATIONS_NAMESPACE}" \
      -o jsonpath='{.status.url}')"
    echo "MLflow URL: ${MLFLOW_URL}"
    echo "MLflow workspace: ${AGENT_NAMESPACE}"
    echo "MLflow experiment: maas-agent-observability"
    exit 0
  fi

  sleep 5
done

echo "Error: the MLflow agent demo Job timed out." >&2
oc get events -n "${AGENT_NAMESPACE}" \
  --sort-by=.lastTimestamp \
  -o custom-columns=LAST:.lastTimestamp,TYPE:.type,REASON:.reason,MESSAGE:.message \
  | tail -30 >&2 || true
oc logs "job/${JOB_NAME}" -n "${AGENT_NAMESPACE}" >&2 || true
exit 1
