from __future__ import annotations

import os
import time
from typing import Any

import httpx
import mlflow
from mlflow.entities import AssessmentSource, AssessmentSourceType, SpanType

MAAS_BASE_URL = os.environ["MAAS_BASE_URL"].rstrip("/")
MAAS_MODEL_ID = os.environ["MAAS_MODEL_ID"]
MAAS_API_KEY = os.environ["MAAS_API_KEY"]
MLFLOW_EXPERIMENT = os.environ.get("MLFLOW_EXPERIMENT", "maas-agent-observability")
RATE_LIMIT_REQUESTS = int(os.environ.get("AGENT_DEMO_RATE_LIMIT_REQUESTS", "12"))
CURRENT_API_KEY = MAAS_API_KEY
EXPECTED_TOOL_SEQUENCE = [
    "check_policy",
    "lookup_governance_context",
    "discover_model",
    "call_model",
    "format_result",
]

mlflow.set_experiment(MLFLOW_EXPERIMENT)

http_client = httpx.Client(
    base_url=MAAS_BASE_URL,
    timeout=60,
    verify=os.environ.get("REQUESTS_CA_BUNDLE", True),
)


def authorization_headers(api_key: str | None = None) -> dict[str, str]:
    key = api_key or CURRENT_API_KEY
    return {"Authorization": f"Bearer {key}"}


@mlflow.trace(span_type=SpanType.TOOL)
def check_policy(scenario: str) -> dict[str, Any]:
    expected_status = {
        "authorized": 200,
        "unauthorized": "401 or 403",
        "rate-limited": 429,
    }[scenario]
    return {
        "subscription": "simulator-free",
        "model": MAAS_MODEL_ID,
        "expected_status": expected_status,
        "policy": "authenticated users may call the simulator through the free-tier subscription",
    }


@mlflow.trace(span_type=SpanType.TOOL)
def lookup_governance_context() -> dict[str, str]:
    return {
        "context": (
            "Red Hat AI provides governed model access through MaaS and agent "
            "observability through MLflow traces and assessments."
        )
    }


@mlflow.trace(span_type=SpanType.TOOL)
def discover_model() -> str:
    response = http_client.get("/v1/models", headers=authorization_headers())
    response.raise_for_status()
    payload = response.json()
    for model in payload.get("data", []):
        model_id = model.get("id", "")
        if model_id == MAAS_MODEL_ID:
            return model_id
    raise RuntimeError(f"MaaS did not return the model {MAAS_MODEL_ID}")


def chat_payload(model_id: str, max_tokens: int) -> dict[str, Any]:
    return {
        "model": model_id,
        "messages": [
            {
                "role": "user",
                "content": "Explain how MaaS governance and MLflow observability work together.",
            }
        ],
        "max_tokens": max_tokens,
    }


@mlflow.trace(span_type=SpanType.LLM)
def call_model(
    model_id: str,
    mode: str,
) -> dict[str, Any]:
    span = mlflow.get_current_active_span()
    span.set_attributes(
        {
            "maas.model_id": model_id,
            "maas.mode": mode,
        }
    )

    if mode == "rate-limit":
        statuses: list[int] = []
        final_response: httpx.Response | None = None
        for _ in range(RATE_LIMIT_REQUESTS):
            final_response = http_client.post(
                "/v1/chat/completions",
                headers=authorization_headers(),
                json=chat_payload(model_id, 100),
            )
            statuses.append(final_response.status_code)
            span.set_attribute("maas.status_codes", ",".join(map(str, statuses)))
            if final_response.status_code == 429:
                break
            time.sleep(0.2)

        if final_response is None:
            raise RuntimeError("The rate-limit scenario did not execute any requests.")
        if final_response.status_code != 429:
            raise RuntimeError(
                "MaaS did not enforce the free-tier rate limit within "
                f"{RATE_LIMIT_REQUESTS} requests."
            )
        return {
            "status_code": final_response.status_code,
            "status_codes": statuses,
            "rate_limited": final_response.status_code == 429,
            "response": final_response.text[:2000],
        }

    key = "invalid-maas-key" if mode == "unauthorized" else CURRENT_API_KEY
    response = http_client.post(
        "/v1/chat/completions",
        headers=authorization_headers(key),
        json=chat_payload(model_id, 20),
    )
    span.set_attribute("maas.status_code", response.status_code)
    content = ""
    if response.status_code == 200:
        content = response.json()["choices"][0]["message"]["content"]
    return {
        "status_code": response.status_code,
        "content": content,
        "response": response.text[:2000],
    }


@mlflow.trace(span_type=SpanType.TOOL)
def format_result(scenario: str, model_result: dict[str, Any]) -> dict[str, Any]:
    status_code = model_result["status_code"]
    return {
        "scenario": scenario,
        "governance_status": "allowed" if status_code == 200 else "blocked",
        "maas_status_code": status_code,
        "model_output": model_result.get("content", ""),
    }


@mlflow.trace(span_type=SpanType.AGENT, name="maas_governed_agent")
def run_scenario(scenario: str) -> dict[str, Any]:
    span = mlflow.get_current_active_span()
    span.set_attributes(
        {
            "demo.scenario": scenario,
            "maas.subscription": "simulator-free",
            "maas.model_id": MAAS_MODEL_ID,
        }
    )

    policy = check_policy(scenario)
    context = lookup_governance_context()
    model_id = discover_model()
    mode = {
        "authorized": "authorized",
        "unauthorized": "unauthorized",
        "rate-limited": "rate-limit",
    }[scenario]
    model_result = call_model(model_id, mode)
    result = format_result(scenario, model_result)

    return {
        "trace_id": span.trace_id,
        "scenario": scenario,
        "status_code": model_result["status_code"],
        "rate_limited": model_result.get("rate_limited", False),
        "model_id": model_id,
        "policy": policy,
        "context": context,
        "result": result,
    }


def expected_statuses(scenario: str) -> set[int]:
    if scenario == "authorized":
        return {200}
    if scenario == "unauthorized":
        return {401, 403}
    return {429}


def log_assessment(
    trace_id: str,
    name: str,
    value: bool,
    rationale: str,
    scenario: str,
    metadata: dict[str, Any] | None = None,
) -> None:
    mlflow.log_feedback(
        trace_id=trace_id,
        name=name,
        value=value,
        rationale=rationale,
        metadata={"scenario": scenario, **(metadata or {})},
        source=AssessmentSource(
            source_type=AssessmentSourceType.CODE,
            source_id="maas-agent-demo",
        ),
    )


def evaluate_result(result: dict[str, Any]) -> None:
    scenario = result["scenario"]
    status_matches = result["status_code"] in expected_statuses(scenario)
    trace = mlflow.get_trace(result["trace_id"])
    actual_tool_sequence = [
        span.name for span in trace.data.spans if span.span_type != SpanType.AGENT
    ]
    tools_match = actual_tool_sequence == EXPECTED_TOOL_SEQUENCE

    log_assessment(
        result["trace_id"],
        "governance_policy_enforced",
        status_matches,
        f"MaaS returned HTTP {result['status_code']} for the {scenario} scenario.",
        scenario,
        None,
    )
    if not tools_match:
        print(
            "Warning: unexpected tool sequence: "
            f"{', '.join(actual_tool_sequence)}",
            flush=True,
        )
    log_assessment(
        result["trace_id"],
        "tool_accuracy_ok",
        tools_match,
        "The agent executed the expected policy, context, discovery, model, and formatting tools.",
        scenario,
        {"tool_sequence": actual_tool_sequence},
    )


def main() -> None:
    print(f"MLflow experiment: {MLFLOW_EXPERIMENT}")
    for scenario in ("authorized", "unauthorized", "rate-limited"):
        print(f"Running {scenario} scenario...")
        result = run_scenario(scenario)
        mlflow.flush_trace_async_logging()
        evaluate_result(result)
        print(
            f"{scenario}: HTTP {result['status_code']}, "
            f"trace {result['trace_id']}"
        )

    print("Agent demo traces and assessments are ready in MLflow.")


if __name__ == "__main__":
    main()
