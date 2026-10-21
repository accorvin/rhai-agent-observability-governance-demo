#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SHARED_DIR="${REPO_DIR}/shared"
OPERATOR_MANIFEST="${SHARED_DIR}/manifests/operator.yaml"
MAAS_OPERATOR_MANIFEST="${SHARED_DIR}/manifests/maas/operators.yaml"
MAAS_PLATFORM_MANIFEST="${SHARED_DIR}/manifests/maas/platform.yaml"
MAAS_KUADRANT_MANIFEST="${SHARED_DIR}/manifests/maas/kuadrant.yaml"
MAAS_GATEWAY_TEMPLATE="${SHARED_DIR}/manifests/maas/gateway.template.yaml"
MAAS_GATEWAY_ROUTE_TEMPLATE="${SHARED_DIR}/manifests/maas/gateway-route.template.yaml"
MAAS_INFRASTRUCTURE_NAMESPACE_MANIFEST="${SHARED_DIR}/manifests/maas/infrastructure-namespace.yaml"
MAAS_DSCI_MANIFEST="${SHARED_DIR}/manifests/maas/dscinitialization.yaml"
MAAS_POSTGRES_MANIFEST="${SHARED_DIR}/manifests/maas/postgres.yaml"
MAAS_DASHBOARD_PATCH="${SHARED_DIR}/manifests/maas/dashboard-config-patch.yaml"
DSC_MANIFEST="${SHARED_DIR}/manifests/datasciencecluster.yaml"
RHOAI_CHANNEL="${RHOAI_CHANNEL:-stable-3.x}"
RHOAI_TIMEOUT_SECONDS="${RHOAI_TIMEOUT_SECONDS:-1800}"
MAAS_HOSTNAME="${MAAS_HOSTNAME:-}"
RHOAI_APPLICATIONS_NAMESPACE="redhat-ods-applications"
MAAS_INFRASTRUCTURE_NAMESPACE="redhat-ai-gateway-infra"

if ! command -v oc >/dev/null 2>&1; then
  echo "Error: the OpenShift CLI (oc) is required." >&2
  exit 1
fi

if ! oc whoami >/dev/null 2>&1; then
  echo "Error: no authenticated OpenShift CLI session. Run oc login first." >&2
  exit 1
fi

if ! [[ "${RHOAI_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: RHOAI_TIMEOUT_SECONDS must be a positive integer." >&2
  exit 1
fi

OPENSHIFT_VERSION="$(oc get clusterversion version -o jsonpath='{.status.desired.version}')"
LOWEST_OPENSHIFT_VERSION="$(printf '4.19.9\n%s\n' "${OPENSHIFT_VERSION}" | sort -V | head -n 1)"
if [[ -z "${OPENSHIFT_VERSION}" || "${LOWEST_OPENSHIFT_VERSION}" != "4.19.9" ]]; then
  echo "Error: OpenShift 4.19.9 or newer is required; found ${OPENSHIFT_VERSION:-unknown}." >&2
  exit 1
fi

if [[ -n "${MAAS_HOSTNAME}" && ! "${MAAS_HOSTNAME}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
  echo "Error: MAAS_HOSTNAME must be a valid lowercase DNS hostname." >&2
  exit 1
fi

TIMEOUT="${RHOAI_TIMEOUT_SECONDS}s"

log() {
  printf '\n==> %s\n' "$*"
}

wait_for_subscription() {
  local namespace="$1"
  local subscription="$2"
  local current_csv

  log "Waiting for the ${subscription} subscription to resolve..."
  oc wait \
    --for=jsonpath='{.status.state}'=AtLatestKnown \
    "subscription/${subscription}" \
    -n "${namespace}" \
    --timeout="${TIMEOUT}"

  current_csv="$(oc get subscription "${subscription}" \
    -n "${namespace}" \
    -o jsonpath='{.status.currentCSV}')"

  if [[ -z "${current_csv}" ]]; then
    echo "Error: the ${subscription} subscription did not report a current CSV." >&2
    exit 1
  fi

  log "Waiting for ${current_csv} to succeed..."
  oc wait \
    --for=jsonpath='{.status.phase}'=Succeeded \
    "csv/${current_csv}" \
    -n "${namespace}" \
    --timeout="${TIMEOUT}"
}

wait_for_crd() {
  local crd="$1"

  log "Waiting for the ${crd} CRD..."
  oc wait \
    --for=condition=Established \
    "crd/${crd}" \
    --timeout="${TIMEOUT}"
}

wait_for_kuadrant_ready() {
  local grace_timeout="$1"
  local reason
  local operator_pod

  if oc wait \
    --for=condition=Ready \
    kuadrant/kuadrant \
    -n kuadrant-system \
    --timeout="${grace_timeout}"; then
    return
  fi

  reason="$(oc get kuadrant kuadrant \
    -n kuadrant-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}')"
  if [[ "${reason}" != "MissingDependency" ]]; then
    echo "Error: Kuadrant is not Ready (reason: ${reason:-unknown})." >&2
    exit 1
  fi

  log "Restarting the Kuadrant operator after its Authorino dependency became available..."
  operator_pod="$(oc get pods \
    -n openshift-operators \
    -l app=kuadrant,control-plane=controller-manager \
    -o jsonpath='{.items[0].metadata.name}')"
  if [[ -z "${operator_pod}" ]]; then
    echo "Error: the Kuadrant operator pod could not be found." >&2
    exit 1
  fi

  oc delete pod "${operator_pod}" -n openshift-operators
  oc wait \
    --for=delete \
    "pod/${operator_pod}" \
    -n openshift-operators \
    --timeout="${TIMEOUT}"
  oc wait \
    --for=condition=Ready \
    pod \
    -l app=kuadrant,control-plane=controller-manager \
    -n openshift-operators \
    --timeout="${TIMEOUT}"
  oc wait \
    --for=condition=Ready \
    kuadrant/kuadrant \
    -n kuadrant-system \
    --timeout="${TIMEOUT}"
}

render_manifest() {
  local template="$1"

  sed \
    -e "s|\${MAAS_HOSTNAME}|${MAAS_HOSTNAME}|g" \
    -e "s|\${CERT_NAME}|${CERT_NAME}|g" \
    "${template}" | oc apply -f -
}

log "Applying the RHOAI and MaaS prerequisite operators..."
oc apply -f "${OPERATOR_MANIFEST}" -f "${MAAS_OPERATOR_MANIFEST}"

if [[ "${RHOAI_CHANNEL}" != "stable-3.x" ]]; then
  echo "Setting the RHOAI OLM channel to ${RHOAI_CHANNEL}..."
  oc patch subscription rhods-operator \
    -n redhat-ods-operator \
    --type=merge \
    -p "{\"spec\":{\"channel\":\"${RHOAI_CHANNEL}\"}}"
fi

wait_for_subscription redhat-ods-operator rhods-operator
wait_for_subscription cert-manager-operator openshift-cert-manager-operator
wait_for_subscription openshift-operators rhcl-operator
wait_for_subscription openshift-lws-operator leader-worker-set

CURRENT_CSV="$(oc get subscription rhods-operator \
  -n redhat-ods-operator \
  -o jsonpath='{.status.currentCSV}')"
RHOAI_VERSION="$(oc get csv "${CURRENT_CSV}" \
  -n redhat-ods-operator \
  -o jsonpath='{.spec.version}')"
LOWEST_VERSION="$(printf '3.5\n%s\n' "${RHOAI_VERSION}" | sort -V | head -n 1)"

if [[ -z "${RHOAI_VERSION}" || "${LOWEST_VERSION}" != "3.5" ]]; then
  echo "Error: RHOAI 3.5 or newer is required for the RHOAI 3.5 MaaS component; found ${RHOAI_VERSION:-unknown}." >&2
  exit 1
fi

log "Detected RHOAI ${RHOAI_VERSION}."

wait_for_crd datascienceclusters.datasciencecluster.opendatahub.io
wait_for_crd dscinitializations.dscinitialization.opendatahub.io
wait_for_crd gatewayclasses.gateway.networking.k8s.io
wait_for_crd kuadrants.kuadrant.io
wait_for_crd authorinos.operator.authorino.kuadrant.io

log "Applying the MaaS gateway platform..."
oc apply -f "${MAAS_PLATFORM_MANIFEST}"

log "Waiting for the OpenShift GatewayClass to be accepted..."
oc wait \
  --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True \
  gatewayclass/openshift-default \
  --timeout="${TIMEOUT}"

log "Applying Kuadrant and Authorino..."
oc apply -f "${MAAS_KUADRANT_MANIFEST}"

log "Waiting for the RHCL dependency operators..."
oc wait \
  --for=condition=Available \
  deployment/authorino-operator \
  -n openshift-operators \
  --timeout="${TIMEOUT}"
oc wait \
  --for=condition=Available \
  deployment/kuadrant-operator-controller-manager \
  -n openshift-operators \
  --timeout="${TIMEOUT}"

log "Waiting for Kuadrant and the initial Authorino deployment..."
wait_for_kuadrant_ready 120s
oc wait \
  --for=condition=Available \
  deployment/authorino \
  -n kuadrant-system \
  --timeout="${TIMEOUT}"

oc set env deployment/authorino \
  -n kuadrant-system \
  SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
  REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt
oc wait \
  --for=condition=Available \
  deployment/authorino \
  -n kuadrant-system \
  --timeout="${TIMEOUT}"

CLUSTER_DOMAIN="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
if [[ -z "${CLUSTER_DOMAIN}" ]]; then
  echo "Error: the cluster ingress domain could not be determined." >&2
  exit 1
fi

MAAS_HOSTNAME="${MAAS_HOSTNAME:-maas.${CLUSTER_DOMAIN}}"
if [[ ! "${MAAS_HOSTNAME}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
  echo "Error: MAAS_HOSTNAME must be a valid lowercase DNS hostname." >&2
  exit 1
fi

CERT_NAME="$(oc get ingresscontroller/default \
  -n openshift-ingress-operator \
  -o jsonpath='{.spec.defaultCertificate.name}')"
CERT_NAME="${CERT_NAME:-router-certs-default}"
if [[ ! "${CERT_NAME}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  echo "Error: the OpenShift default certificate name is not a valid secret name." >&2
  exit 1
fi

log "Applying the MaaS Gateway at https://${MAAS_HOSTNAME}..."
render_manifest "${MAAS_GATEWAY_TEMPLATE}"

if ! oc wait \
  --for=condition=Programmed \
  gateway/maas-default-gateway \
  -n openshift-ingress \
  --timeout="${TIMEOUT}"; then
  log "The Gateway LoadBalancer address is not ready; applying an OpenShift Route fallback..."
  render_manifest "${MAAS_GATEWAY_ROUTE_TEMPLATE}"
fi

wait_for_kuadrant_ready 120s

log "Applying the MaaS infrastructure namespace..."
oc apply -f "${MAAS_INFRASTRUCTURE_NAMESPACE_MANIFEST}"

if oc get secret postgres-creds -n "${RHOAI_APPLICATIONS_NAMESPACE}" >/dev/null 2>&1; then
  POSTGRES_PASSWORD="$(oc get secret postgres-creds \
    -n "${RHOAI_APPLICATIONS_NAMESPACE}" \
    -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 --decode)"
else
  POSTGRES_PASSWORD=""
  for _password_nibble in {1..48}; do
    POSTGRES_PASSWORD+="$(printf '%x' "$((RANDOM % 16))")"
  done
  oc create secret generic postgres-creds \
    -n "${RHOAI_APPLICATIONS_NAMESPACE}" \
    --from-literal=POSTGRES_USER=maas \
    --from-literal=POSTGRES_DB=maas \
    --from-literal=POSTGRES_PASSWORD="${POSTGRES_PASSWORD}"
fi

if [[ -z "${POSTGRES_PASSWORD}" ]]; then
  echo "Error: the existing PostgreSQL password secret is empty." >&2
  exit 1
fi

POSTGRES_CONNECTION_URL="postgresql://maas:${POSTGRES_PASSWORD}@postgres.${RHOAI_APPLICATIONS_NAMESPACE}.svc:5432/maas?sslmode=disable"
oc create secret generic maas-db-config \
  -n "${RHOAI_APPLICATIONS_NAMESPACE}" \
  --from-literal=DB_CONNECTION_URL="${POSTGRES_CONNECTION_URL}" \
  --dry-run=client \
  -o yaml | oc apply -f -
oc create secret generic maas-db-config \
  -n "${MAAS_INFRASTRUCTURE_NAMESPACE}" \
  --from-literal=DB_CONNECTION_URL="${POSTGRES_CONNECTION_URL}" \
  --dry-run=client \
  -o yaml | oc apply -f -
unset POSTGRES_PASSWORD POSTGRES_CONNECTION_URL

log "Deploying PostgreSQL for the MaaS control plane..."
oc apply -f "${MAAS_POSTGRES_MANIFEST}"
oc wait \
  --for=condition=Available \
  deployment/postgres \
  -n "${RHOAI_APPLICATIONS_NAMESPACE}" \
  --timeout="${TIMEOUT}"

log "Applying the MaaS RHOAI configuration..."
oc apply -f "${MAAS_DSCI_MANIFEST}"
oc wait \
  --for=jsonpath='{.status.phase}'=Ready \
  dscinitialization/default-dsci \
  --timeout="${TIMEOUT}"

oc apply -f "${DSC_MANIFEST}"
oc wait \
  --for=jsonpath='{.status.phase}'=Ready \
  datasciencecluster/default-dsc \
  --timeout="${TIMEOUT}"

for condition in KserveReady ModelsAsAServiceReady OGXReady; do
  log "Waiting for the DataScienceCluster ${condition} condition..."
  oc wait \
    --for=jsonpath="{.status.conditions[?(@.type==\"${condition}\")].status}"=True \
    datasciencecluster/default-dsc \
    --timeout="${TIMEOUT}"
done

log "Enabling the MaaS dashboard controls..."
wait_for_crd odhdashboardconfigs.opendatahub.io
oc patch odhdashboardconfig odh-dashboard-config \
  -n "${RHOAI_APPLICATIONS_NAMESPACE}" \
  --type=merge \
  --patch-file="${MAAS_DASHBOARD_PATCH}"

log "Waiting for the MaaS API..."
oc wait \
  --for=condition=Available \
  deployment/maas-api \
  -n "${MAAS_INFRASTRUCTURE_NAMESPACE}" \
  --timeout="${TIMEOUT}"

log "RHOAI and the MaaS serving infrastructure are ready."
log "Gateway URL: https://${MAAS_HOSTNAME}"
log "Check pods with:"
log "  oc get pods -n ${RHOAI_APPLICATIONS_NAMESPACE}"
log "  oc get pods -n ${MAAS_INFRASTRUCTURE_NAMESPACE}"
