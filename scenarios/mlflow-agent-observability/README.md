# MLflow agent observability

## What this demo shows

- Runs an agent workload against the MaaS CPU simulator.
- Records authorized, unauthorized, and rate-limited MLflow traces.
- Captures nested agent, tool, and LLM spans.
- Adds code-based governance and tool-accuracy assessments.
- Demonstrates how MaaS policy outcomes appear in MLflow observability data.

## Special resources

- No GPU.
- No external model provider or API key.
- Requires the MaaS CPU simulator and MLflow instance from the shared setup.

## Run

1. Complete the shared setup:

   ```bash
   make install
   make deploy-mlflow
   make deploy-model
   ```

2. Generate the agent traces:

   ```bash
   make demo-agent
   ```

3. Open the printed MLflow URL, select the `agent-demo` workspace, and inspect the `maas-agent-observability` experiment.

## What to look for

- Three traces: authorized, unauthorized, and rate-limited.
- Nested agent, tool, and LLM spans in each trace.
- `governance_policy_enforced` and `tool_accuracy_ok` assessments.
- MaaS status codes and model IDs in span attributes.

