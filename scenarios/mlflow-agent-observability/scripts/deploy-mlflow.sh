#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
SCENARIO_DIR="${REPO_DIR}/scenarios/mlflow-agent-observability"
MLFLOW_MANIFEST="${SCENARIO_DIR}/manifests/mlflow/mlflow.yaml"
MLFLOW_TIMEOUT_SECONDS="${MLFLOW_TIMEOUT_SECONDS:-900}"
RHOAI_APPLICATIONS_NAMESPACE="redhat-ods-applications"

if ! command -v oc >/dev/null 2>&1; then
  echo "Error: the OpenShift CLI (oc) is required." >&2
  exit 1
fi

if ! oc whoami >/dev/null 2>&1; then
  echo "Error: no authenticated OpenShift CLI session. Run oc login first." >&2
  exit 1
fi

if ! [[ "${MLFLOW_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: MLFLOW_TIMEOUT_SECONDS must be a positive integer." >&2
  exit 1
fi

TIMEOUT="${MLFLOW_TIMEOUT_SECONDS}s"

MLFLOW_OPERATOR_READY="$(oc get datasciencecluster default-dsc \
  -o jsonpath='{.status.conditions[?(@.type=="MLflowOperatorReady")].status}')"
if [[ "${MLFLOW_OPERATOR_READY}" != "True" ]]; then
  echo "Error: the MLflow operator is not Ready. Run 'make install' first." >&2
  exit 1
fi

echo "Waiting for the MLflow CRD..."
oc wait \
  --for=condition=Established \
  crd/mlflows.mlflow.opendatahub.io \
  --timeout="${TIMEOUT}"

if ! oc get namespace "${RHOAI_APPLICATIONS_NAMESPACE}" >/dev/null 2>&1; then
  echo "Error: the ${RHOAI_APPLICATIONS_NAMESPACE} namespace does not exist. Run 'make install' first." >&2
  exit 1
fi

echo "Deploying the MLflow instance..."
oc apply -f "${MLFLOW_MANIFEST}"

echo "Waiting for MLflow to become available..."
oc wait \
  --for=condition=Available \
  mlflow/mlflow \
  --timeout="${TIMEOUT}"

MLFLOW_URL="$(oc get mlflow mlflow -o jsonpath='{.status.url}')"
echo "MLflow is ready."
if [[ -n "${MLFLOW_URL}" ]]; then
  echo "MLflow URL: ${MLFLOW_URL}"
else
  echo "MLflow URL is not populated yet."
fi
