#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
MODEL_MANIFEST="${REPO_DIR}/shared/manifests/model/simulator.yaml"
MODEL_TIMEOUT_SECONDS="${MODEL_TIMEOUT_SECONDS:-900}"
MODEL_NAME="facebook-opt-125m-simulated"
MODEL_NAMESPACE="llm"
MAAS_NAMESPACE="models-as-a-service"

if ! command -v oc >/dev/null 2>&1; then
  echo "Error: the OpenShift CLI (oc) is required." >&2
  exit 1
fi

if ! oc whoami >/dev/null 2>&1; then
  echo "Error: no authenticated OpenShift CLI session. Run oc login first." >&2
  exit 1
fi

if ! [[ "${MODEL_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: MODEL_TIMEOUT_SECONDS must be a positive integer." >&2
  exit 1
fi

TIMEOUT="${MODEL_TIMEOUT_SECONDS}s"

MAAS_READY="$(oc get datasciencecluster default-dsc \
  -o jsonpath='{.status.conditions[?(@.type=="ModelsAsAServiceReady")].status}')"
if [[ "${MAAS_READY}" != "True" ]]; then
  echo "Error: the MaaS component is not Ready. Run 'make install' first." >&2
  exit 1
fi

for crd in \
  llminferenceservices.serving.kserve.io \
  maasmodelrefs.maas.opendatahub.io \
  maasauthpolicies.maas.opendatahub.io \
  maassubscriptions.maas.opendatahub.io; do
  echo "Waiting for the ${crd} CRD..."
  oc wait --for=condition=Established "crd/${crd}" --timeout="${TIMEOUT}"
done

if ! oc get namespace "${MAAS_NAMESPACE}" >/dev/null 2>&1; then
  echo "Error: the ${MAAS_NAMESPACE} namespace does not exist. Run 'make install' first." >&2
  exit 1
fi

echo "Waiting for the MaaS API..."
oc wait \
  --for=condition=Available \
  deployment/maas-api \
  -n redhat-ai-gateway-infra \
  --timeout="${TIMEOUT}"

echo "Deploying the CPU simulator model..."
oc apply -f "${MODEL_MANIFEST}"

echo "Waiting for the simulator inference service..."
oc wait \
  --for=condition=Ready \
  "llminferenceservice/${MODEL_NAME}" \
  -n "${MODEL_NAMESPACE}" \
  --timeout="${TIMEOUT}"

echo "Waiting for the simulator MaaS model reference..."
oc wait \
  --for=jsonpath='{.status.phase}'=Ready \
  "maasmodelref/${MODEL_NAME}" \
  -n "${MODEL_NAMESPACE}" \
  --timeout="${TIMEOUT}"

echo "Waiting for the simulator MaaS subscription..."
oc wait \
  --for=jsonpath='{.status.phase}'=Active \
  maassubscription/simulator-free \
  -n "${MAAS_NAMESPACE}" \
  --timeout="${TIMEOUT}"

echo "CPU simulator model is ready."
echo "Model resources:"
oc get llminferenceservice "${MODEL_NAME}" -n "${MODEL_NAMESPACE}"
oc get maasmodelref "${MODEL_NAME}" -n "${MODEL_NAMESPACE}"
oc get maasauthpolicy simulator-access -n "${MAAS_NAMESPACE}"
oc get maassubscription simulator-free -n "${MAAS_NAMESPACE}"
