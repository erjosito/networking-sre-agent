import importlib
import os
import unittest
from unittest.mock import Mock, patch


os.environ["DISABLE_AZURE_MONITOR"] = "true"
os.environ["PRIVATE_ENDPOINT_FQDN"] = "storage.example"
os.environ["PRIVATE_ENDPOINT_URL"] = "https://storage.example/"
os.environ["CROSS_HUB_URL"] = "http://10.21.0.4/"
os.environ["ONPREM_URL"] = ""
os.environ["LAB_DEPENDENCY_LATENCY_TARGET"] = "cross_hub_http"
os.environ["LAB_DEPENDENCY_LATENCY_MS"] = "2500"

app_module = importlib.import_module("app")


class ObservabilityApiTests(unittest.TestCase):
    def setUp(self):
        self.client = app_module.app.test_client()

    def test_health(self):
        response = self.client.get("/healthz")
        self.assertEqual(200, response.status_code)
        self.assertEqual("ok", response.get_json()["status"])

    @patch.object(app_module.requests, "get")
    @patch.object(app_module.socket, "getaddrinfo")
    def test_transaction_succeeds(self, getaddrinfo, requests_get):
        getaddrinfo.return_value = [
            (2, 1, 6, "", ("10.1.4.4", 443)),
        ]
        response_mock = Mock(status_code=200, content=b"ok")
        response_mock.raise_for_status.return_value = None
        requests_get.return_value = response_mock

        response = self.client.get(
            "/api/transaction", headers={"X-Lab-Scenario": "unit-test"}
        )

        self.assertEqual(200, response.status_code)
        body = response.get_json()
        self.assertTrue(body["success"])
        self.assertEqual(3, len(body["checks"]))
        self.assertEqual("unit-test", body["scenario"])
        self.assertEqual("baseline", body["profile"])

    @patch.object(app_module.time, "sleep")
    @patch.object(app_module.requests, "get")
    @patch.object(app_module.socket, "getaddrinfo")
    def test_dependency_latency_targets_cross_hub_only(
        self, getaddrinfo, requests_get, sleep
    ):
        getaddrinfo.return_value = [
            (2, 1, 6, "", ("10.1.4.4", 443)),
        ]
        response_mock = Mock(status_code=200, content=b"ok")
        response_mock.raise_for_status.return_value = None
        requests_get.return_value = response_mock

        response = self.client.get(
            "/api/transaction",
            headers={
                "X-Lab-Scenario": "latency-demo",
                "X-Lab-Profile": "dependency-latency",
            },
        )

        self.assertEqual(200, response.status_code)
        body = response.get_json()
        self.assertTrue(body["success"])
        self.assertEqual("dependency-latency", body["profile"])
        sleep.assert_called_once_with(2.5)
        cross_hub = next(
            check for check in body["checks"] if check["name"] == "cross_hub_http"
        )
        self.assertIn("injected 2500 ms latency", cross_hub["detail"])

    @patch.object(app_module.logger, "exception")
    @patch.object(app_module.requests, "get")
    @patch.object(app_module.socket, "getaddrinfo")
    def test_application_exception_keeps_dependencies_successful(
        self, getaddrinfo, requests_get, logger_exception
    ):
        getaddrinfo.return_value = [
            (2, 1, 6, "", ("10.1.4.4", 443)),
        ]
        response_mock = Mock(status_code=200, content=b"ok")
        response_mock.raise_for_status.return_value = None
        requests_get.return_value = response_mock

        response = self.client.get(
            "/api/transaction",
            headers={"X-Lab-Profile": "application-exception"},
        )

        self.assertEqual(503, response.status_code)
        body = response.get_json()
        self.assertFalse(body["success"])
        self.assertTrue(all(check["success"] for check in body["checks"]))
        self.assertEqual("application-exception", body["failure"]["type"])
        self.assertEqual("application", body["failure"]["component"])
        logger_exception.assert_called_once()

    @patch.object(app_module.requests, "get")
    def test_unknown_profile_is_rejected_without_dependency_calls(self, requests_get):
        response = self.client.get(
            "/api/transaction", headers={"X-Lab-Profile": "not-a-profile"}
        )

        self.assertEqual(400, response.status_code)
        body = response.get_json()
        self.assertEqual("unknown-profile", body["error"])
        self.assertEqual(
            ["application-exception", "baseline", "dependency-latency"],
            body["supported_profiles"],
        )
        requests_get.assert_not_called()

    @patch.object(app_module.requests, "get")
    @patch.object(app_module.socket, "getaddrinfo")
    def test_public_private_endpoint_address_fails_transaction(
        self, getaddrinfo, requests_get
    ):
        getaddrinfo.return_value = [
            (2, 1, 6, "", ("20.50.10.20", 443)),
        ]
        response_mock = Mock(status_code=200, content=b"ok")
        response_mock.raise_for_status.return_value = None
        requests_get.return_value = response_mock

        response = self.client.get("/api/transaction")

        self.assertEqual(503, response.status_code)
        body = response.get_json()
        self.assertFalse(body["success"])
        dns_check = next(
            check for check in body["checks"] if check["name"] == "private_endpoint_dns"
        )
        self.assertFalse(dns_check["success"])
        self.assertIn("expected a private endpoint address", dns_check["detail"])


if __name__ == "__main__":
    unittest.main()
