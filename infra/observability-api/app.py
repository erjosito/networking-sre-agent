import logging
import os
import socket
import time
from dataclasses import asdict, dataclass
from typing import Callable

import requests
from azure.monitor.opentelemetry import configure_azure_monitor
from flask import Flask, jsonify, request
from opentelemetry import metrics, trace
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.semconv.resource import ResourceAttributes
from opentelemetry.trace import Status, StatusCode


SERVICE_NAME = os.getenv("OTEL_SERVICE_NAME", "netsre-observability-api")
REQUEST_TIMEOUT_SECONDS = float(os.getenv("DEPENDENCY_TIMEOUT_SECONDS", "5"))
PRIVATE_ADDRESS_PREFIX = os.getenv("PRIVATE_ADDRESS_PREFIX", "10.")
DEFAULT_PROFILE = "baseline"
DEPENDENCY_LATENCY_PROFILE = "dependency-latency"
APPLICATION_EXCEPTION_PROFILE = "application-exception"
SUPPORTED_PROFILES = frozenset(
    {
        DEFAULT_PROFILE,
        DEPENDENCY_LATENCY_PROFILE,
        APPLICATION_EXCEPTION_PROFILE,
    }
)
DEPENDENCY_LATENCY_TARGET = (
    os.getenv("LAB_DEPENDENCY_LATENCY_TARGET", "cross_hub_http").strip()
    or "cross_hub_http"
)
DEPENDENCY_LATENCY_MS = float(os.getenv("LAB_DEPENDENCY_LATENCY_MS", "3000"))
if DEPENDENCY_LATENCY_MS < 0:
    raise RuntimeError("LAB_DEPENDENCY_LATENCY_MS must be non-negative")


class ApplicationProfileError(RuntimeError):
    pass


def configure_telemetry() -> bool:
    if os.getenv("DISABLE_AZURE_MONITOR", "").lower() in {"1", "true", "yes"}:
        return False

    connection_string = os.getenv("APPLICATIONINSIGHTS_CONNECTION_STRING")
    if not connection_string:
        raise RuntimeError("APPLICATIONINSIGHTS_CONNECTION_STRING is required")

    configure_azure_monitor(
        connection_string=connection_string,
        resource=Resource.create(
            {
                ResourceAttributes.SERVICE_NAME: SERVICE_NAME,
                ResourceAttributes.SERVICE_INSTANCE_ID: socket.gethostname(),
                "deployment.environment.name": "networking-sre-lab",
            }
        ),
        logger_name="netsre.observability",
        instrumentation_options={"flask": {"enabled": False}},
    )
    return True


telemetry_enabled = configure_telemetry()
logger = logging.getLogger("netsre.observability")
tracer = trace.get_tracer(SERVICE_NAME)
meter = metrics.get_meter(SERVICE_NAME)
transaction_counter = meter.create_counter(
    "netsre.synthetic.transactions",
    description="Synthetic dependency transactions executed by the lab API",
)
failure_counter = meter.create_counter(
    "netsre.synthetic.failures",
    description="Failed synthetic dependencies",
)
dependency_duration = meter.create_histogram(
    "netsre.dependency.duration",
    unit="ms",
    description="Dependency check duration",
)


@dataclass
class CheckResult:
    name: str
    target: str
    success: bool
    duration_ms: float
    detail: str


def timed_check(
    name: str,
    target: str,
    operation: Callable[[], str],
    profile: str = DEFAULT_PROFILE,
) -> CheckResult:
    started = time.perf_counter()
    with tracer.start_as_current_span(
        f"lab.dependency.{name}", kind=trace.SpanKind.CLIENT
    ) as span:
        try:
            span.set_attribute("lab.dependency.name", name)
            span.set_attribute("lab.profile", profile)
            span.set_attribute("server.address", target)
            latency_injected = (
                profile == DEPENDENCY_LATENCY_PROFILE
                and name == DEPENDENCY_LATENCY_TARGET
                and DEPENDENCY_LATENCY_MS > 0
            )
            span.set_attribute("lab.latency.injected", latency_injected)
            if latency_injected:
                span.set_attribute(
                    "lab.latency.injected_duration_ms", DEPENDENCY_LATENCY_MS
                )
                time.sleep(DEPENDENCY_LATENCY_MS / 1000)
            detail = operation()
            if latency_injected:
                detail = f"injected {DEPENDENCY_LATENCY_MS:g} ms latency; {detail}"
            span.set_attribute("lab.dependency.success", True)
            success = True
        except Exception as exc:
            span.record_exception(exc)
            span.set_status(Status(StatusCode.ERROR, str(exc)))
            span.set_attribute("lab.dependency.success", False)
            detail = f"{type(exc).__name__}: {exc}"
            success = False

    duration_ms = round((time.perf_counter() - started) * 1000, 2)
    attributes = {
        "lab.dependency.name": name,
        "lab.profile": profile,
        "server.address": target,
    }
    dependency_duration.record(duration_ms, attributes)
    if not success:
        failure_counter.add(1, attributes)
        logger.error(
            "dependency_check_failed",
            extra={
                "dependency_name": name,
                "dependency_target": target,
                "duration_ms": duration_ms,
                "failure_detail": detail,
                "lab_profile": profile,
            },
        )
    else:
        logger.info(
            "dependency_check_succeeded",
            extra={
                "dependency_name": name,
                "dependency_target": target,
                "duration_ms": duration_ms,
                "lab_profile": profile,
            },
        )
    return CheckResult(name, target, success, duration_ms, detail)


def resolve_private_endpoint(hostname: str) -> str:
    addresses = sorted(
        {
            item[4][0]
            for item in socket.getaddrinfo(hostname, 443, type=socket.SOCK_STREAM)
        }
    )
    if not addresses:
        raise RuntimeError("DNS returned no addresses")
    if not any(address.startswith(PRIVATE_ADDRESS_PREFIX) for address in addresses):
        raise RuntimeError(
            f"expected a private endpoint address starting with "
            f"{PRIVATE_ADDRESS_PREFIX}, got {addresses}"
        )
    return f"resolved addresses: {addresses}"


def http_get(url: str) -> str:
    response = requests.get(
        url,
        timeout=REQUEST_TIMEOUT_SECONDS,
        headers={"User-Agent": f"{SERVICE_NAME}/1.0"},
    )
    response.raise_for_status()
    return f"HTTP {response.status_code}, {len(response.content)} bytes"


def configured_checks() -> list[tuple[str, str, Callable[[], str]]]:
    checks: list[tuple[str, str, Callable[[], str]]] = []
    private_endpoint_fqdn = os.getenv("PRIVATE_ENDPOINT_FQDN", "").strip()
    private_endpoint_url = os.getenv("PRIVATE_ENDPOINT_URL", "").strip()
    cross_hub_url = os.getenv("CROSS_HUB_URL", "").strip()
    onprem_url = os.getenv("ONPREM_URL", "").strip()

    if private_endpoint_fqdn:
        checks.append(
            (
                "private_endpoint_dns",
                private_endpoint_fqdn,
                lambda: resolve_private_endpoint(private_endpoint_fqdn),
            )
        )
    if private_endpoint_url:
        checks.append(
            (
                "private_endpoint_http",
                private_endpoint_url,
                lambda: http_get(private_endpoint_url),
            )
        )
    if cross_hub_url:
        checks.append(
            ("cross_hub_http", cross_hub_url, lambda: http_get(cross_hub_url))
        )
    if onprem_url:
        checks.append(("onprem_http", onprem_url, lambda: http_get(onprem_url)))
    return checks


app = Flask(__name__)
if telemetry_enabled:
    FlaskInstrumentor().instrument_app(app)


@app.get("/healthz")
def healthz():
    return jsonify({"status": "ok", "service": SERVICE_NAME})


@app.get("/api/transaction")
def transaction():
    scenario = request.headers.get("X-Lab-Scenario", "baseline")
    profile = request.headers.get("X-Lab-Profile", DEFAULT_PROFILE).strip().lower()
    if profile not in SUPPORTED_PROFILES:
        logger.warning(
            "unknown_lab_profile",
            extra={"lab_profile": profile, "lab_scenario": scenario},
        )
        return (
            jsonify(
                {
                    "error": "unknown-profile",
                    "profile": profile,
                    "supported_profiles": sorted(SUPPORTED_PROFILES),
                }
            ),
            400,
        )

    with tracer.start_as_current_span("lab.synthetic.transaction") as span:
        span.set_attribute("lab.scenario", scenario)
        span.set_attribute("lab.profile", profile)
        results = [
            timed_check(name, target, operation, profile)
            for name, target, operation in configured_checks()
        ]
        dependencies_succeeded = all(result.success for result in results) and bool(
            results
        )
        application_failure = None
        if profile == APPLICATION_EXCEPTION_PROFILE and dependencies_succeeded:
            try:
                raise ApplicationProfileError(
                    "application-exception profile failed after all dependencies succeeded"
                )
            except ApplicationProfileError as exc:
                span.record_exception(exc)
                span.set_status(Status(StatusCode.ERROR, str(exc)))
                logger.exception(
                    "application_profile_exception",
                    extra={
                        "lab_profile": profile,
                        "lab_scenario": scenario,
                        "dependency_checks_succeeded": True,
                    },
                )
                application_failure = {
                    "type": "application-exception",
                    "component": "application",
                    "detail": str(exc),
                }

        succeeded = dependencies_succeeded and application_failure is None
        span.set_attribute("lab.transaction.success", succeeded)
        span.set_attribute("lab.transaction.check_count", len(results))
        span.set_attribute(
            "lab.transaction.dependencies_succeeded", dependencies_succeeded
        )
        if not succeeded and application_failure is None:
            span.set_status(Status(StatusCode.ERROR, "dependency check failed"))

    transaction_counter.add(
        1,
        {
            "lab.scenario": scenario,
            "lab.profile": profile,
            "lab.transaction.success": str(succeeded).lower(),
        },
    )
    payload = {
        "service": SERVICE_NAME,
        "scenario": scenario,
        "profile": profile,
        "success": succeeded,
        "checks": [asdict(result) for result in results],
    }
    if application_failure:
        payload["failure"] = application_failure
    return jsonify(payload), 200 if succeeded else 503


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8080")))
