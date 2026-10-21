#!/usr/bin/env bash
set -Eeuo pipefail

CLUSTER_DOMAIN=""
MAAS_HOST=""
API_KEY=""
API_KEY_ID=""
RESPONSE_FILE=""

cleanup() {
  if [[ -n "${API_KEY_ID:-}" && -n "${MAAS_HOST:-}" ]]; then
    curl -sS -k -X DELETE \
      -H "Authorization: Bearer $(oc whoami -t)" \
      "https://${MAAS_HOST}/maas-api/v1/api-keys/${API_KEY_ID}" \
      >/dev/null 2>&1 || true
  fi

  if [[ -n "${RESPONSE_FILE:-}" ]]; then
    rm -f "${RESPONSE_FILE}"
  fi

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

if ! oc get maasmodelref facebook-opt-125m-simulated -n llm >/dev/null 2>&1; then
  echo "Error: the simulator model is not deployed. Run 'make deploy-model' first." >&2
  exit 1
fi

CLUSTER_DOMAIN="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
if [[ -z "${CLUSTER_DOMAIN}" ]]; then
  echo "Error: the cluster ingress domain could not be determined." >&2
  exit 1
fi

MAAS_HOST="${MAAS_HOSTNAME:-maas.${CLUSTER_DOMAIN}}"
RESPONSE_FILE="$(mktemp)"

echo "Testing MaaS at https://${MAAS_HOST}"

HTTP_CODE="$(curl -sS -k --connect-timeout 10 --max-time 30 \
  -o "${RESPONSE_FILE}" \
  -w '%{http_code}' \
  "https://${MAAS_HOST}/maas-api/health")"
if [[ "${HTTP_CODE}" != "200" ]]; then
  echo "Error: the MaaS health endpoint returned HTTP ${HTTP_CODE}." >&2
  cat "${RESPONSE_FILE}" >&2
  exit 1
fi
echo "PASS: MaaS health endpoint returned HTTP 200"

API_KEY_RESPONSE="$(curl -sS -k --connect-timeout 10 --max-time 30 \
  -X POST \
  -H "Authorization: Bearer $(oc whoami -t)" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"maas-smoke-$(date +%s)\",\"description\":\"Temporary MaaS smoke-test key\",\"expiresIn\":\"1h\",\"subscription\":\"simulator-free\"}" \
  "https://${MAAS_HOST}/maas-api/v1/api-keys")"

API_KEY="$(printf '%s' "${API_KEY_RESPONSE}" | jq -r '.key // empty')"
API_KEY_ID="$(printf '%s' "${API_KEY_RESPONSE}" | jq -r '.id // empty')"
if [[ -z "${API_KEY}" || -z "${API_KEY_ID}" ]]; then
  echo "Error: MaaS API-key creation failed." >&2
  exit 1
fi
echo "PASS: created temporary MaaS API key ${API_KEY_ID}"

HTTP_CODE="$(curl -sS -k --connect-timeout 10 --max-time 30 \
  -o "${RESPONSE_FILE}" \
  -w '%{http_code}' \
  -H "Authorization: Bearer ${API_KEY}" \
  "https://${MAAS_HOST}/v1/models")"
if [[ "${HTTP_CODE}" != "200" ]]; then
  echo "Error: model discovery returned HTTP ${HTTP_CODE}." >&2
  cat "${RESPONSE_FILE}" >&2
  exit 1
fi

MODEL_ID="$(jq -r '.data[] | select(.id | contains("facebook/opt-125m")) | .id' "${RESPONSE_FILE}" | head -n 1)"
if [[ -z "${MODEL_ID}" ]]; then
  echo "Error: the simulator model was not returned by /v1/models." >&2
  jq . "${RESPONSE_FILE}" >&2
  exit 1
fi
echo "PASS: model discovery returned ${MODEL_ID}"

HTTP_CODE="$(curl -sS -k --connect-timeout 10 --max-time 60 \
  -o "${RESPONSE_FILE}" \
  -w '%{http_code}' \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello from MaaS\"}],\"max_tokens\":25}" \
  "https://${MAAS_HOST}/v1/chat/completions")"
if [[ "${HTTP_CODE}" != "200" ]]; then
  echo "Error: inference returned HTTP ${HTTP_CODE}." >&2
  cat "${RESPONSE_FILE}" >&2
  exit 1
fi

if ! jq -e '.choices[0].message.content' "${RESPONSE_FILE}" >/dev/null; then
  echo "Error: inference did not return a chat completion." >&2
  jq . "${RESPONSE_FILE}" >&2
  exit 1
fi
echo "PASS: inference returned a chat completion"

HTTP_CODE="$(curl -sS -k --connect-timeout 10 --max-time 30 \
  -o /dev/null \
  -w '%{http_code}' \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":5}" \
  "https://${MAAS_HOST}/v1/chat/completions")"
if [[ "${HTTP_CODE}" != "401" && "${HTTP_CODE}" != "403" ]]; then
  echo "Error: an unauthenticated request returned HTTP ${HTTP_CODE}; expected 401 or 403." >&2
  exit 1
fi
echo "PASS: unauthenticated inference was rejected with HTTP ${HTTP_CODE}"
echo "MaaS smoke test passed."
