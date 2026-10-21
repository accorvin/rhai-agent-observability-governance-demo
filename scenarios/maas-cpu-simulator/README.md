# MaaS CPU simulator

## What this demo shows

- Deploys a CPU-only OpenAI-compatible simulator through MaaS.
- Exercises governed model access with a temporary API key.
- Verifies authenticated inference and unauthenticated rejection.
- Optionally demonstrates free-tier rate limiting.

## Special resources

- No GPU.
- No external model provider or API key.
- Requires an OpenShift cluster with RHOAI and MaaS installed.

## Run

1. Install the shared demo infrastructure:

   ```bash
   make install
   ```

2. Deploy the simulator:

   ```bash
   make deploy-model
   ```

3. Run the end-to-end smoke test:

   ```bash
   make test-model
   ```

## What to look for

- The model reference and inference service report `Ready`.
- The smoke test returns HTTP `200` for an authorized request.
- The smoke test rejects an unauthenticated request.
- Optional rate-limit testing eventually returns HTTP `429`.

## Optional rate-limit test

Create an API key for the `simulator-free` subscription in the RHOAI dashboard, export it as `API_KEY`, then run:

```bash
CLUSTER_DOMAIN="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
MAAS_HOST="${MAAS_HOSTNAME:-maas.${CLUSTER_DOMAIN}}"
MODEL_ID="publishers/llm/models/facebook/opt-125m"

for _ in {1..16}; do
  curl -sk -o /dev/null -w '%{http_code}\n' \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"Write a long response\"}],\"max_tokens\":50}" \
    "https://${MAAS_HOST}/v1/chat/completions"
done | sort | uniq -c
```

