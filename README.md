# Red Hat AI Agent Observability and Governance Demo

Resources for demoing agent observability and governance capabilities in Red Hat AI.

## Prerequisites

The only infrastructure prerequisite is a connected OpenShift 4.19.9 or newer cluster that you can administer. The cluster needs a default storage class and must be able to pull Red Hat Operator and container images.

Use an authenticated `oc` session. Testing the model and generating agent traces require `curl` and `jq`.

## Demo scenarios

- [MaaS CPU simulator](scenarios/maas-cpu-simulator/README.md): verifies governed inference and optional rate limiting with no GPU.
- [MLflow agent observability](scenarios/mlflow-agent-observability/README.md): records authorized, unauthorized, and rate-limited agent traces with governance and tool assessments.

## Options

- `MAAS_HOSTNAME`: override the default `maas.<cluster-domain>` gateway hostname.
- `RHOAI_TIMEOUT_SECONDS`: increase the installation timeout.
- `MODEL_TIMEOUT_SECONDS`: increase the model deployment timeout.
- `MLFLOW_TIMEOUT_SECONDS`: increase the MLflow deployment timeout.
- `AGENT_DEMO_TIMEOUT_SECONDS`: increase the agent demo Job timeout.
- `AGENT_DEMO_RATE_LIMIT_REQUESTS`: increase requests used to trigger the free-tier rate limit.

