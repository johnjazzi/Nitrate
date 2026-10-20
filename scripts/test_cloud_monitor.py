#!/usr/bin/env python3
"""Unit tests for the Xcode Cloud start/monitor CLI.

Every network interaction is a scripted fake; nothing here talks to Apple or to
GitHub, and nothing writes outside a temporary directory. The HTTP adapter and the
clock are injected through the public ``main(...)`` seams, so the production code
paths (``urllib``, ``SystemClock``, PyJWT signing) are exercised only through their
real implementations where a test deliberately uses them.

The scripted responses use the exact shapes of the App Store Connect OpenAPI
4.5.1 schemas: ``CiAction`` (``actionType``/``scheme``/``platform``/
``testConfiguration.testDestinations``), ``CiBuildAction``, ``CiTestResult``
(``status`` is a ``CiTestStatus``), ``CiBuildRun.executionProgress`` and the
``ciWorkflows`` -> ``product`` / ``repository`` relationships.
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import cast

sys.path.insert(0, str(Path(__file__).resolve().parent))

import cloud_monitor as cm  # noqa: E402
from cloud_monitor import HttpResponse  # noqa: E402

try:
    import jwt as pyjwt
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec

    HAVE_CRYPTO = True
except ImportError:  # pragma: no cover - only on a bare interpreter
    HAVE_CRYPTO = False

WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/cloud.yml"
TEST_WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/xcode.yml"

API = cm.API_BASE
WID = "11111111-2222-3333-4444-555555555555"
REPO = "rep-0001"
PROD = "prod-0001"
RUN_ID = "aaaa-bbbb-cccc-dddd"
TEST_ACTION_ID = "action-test-1"
SHA = "0123456789abcdef0123456789abcdef01234567"


# --------------------------------------------------------------------------- #
# Fixtures (fake HTTP adapter + fake clock)
# --------------------------------------------------------------------------- #
@dataclass
class HttpCall:
    method: str
    url: str
    headers: dict
    body: bytes | None
    timeout: float


class FakeHttp:
    """Longest-needle routing fake. The last response for a route repeats."""

    def __init__(self):
        self.calls: list[HttpCall] = []
        self._routes: list[list] = []

    def route(self, method: str, needle: str, *responses) -> None:
        assert responses, "a route needs at least one response"
        self._routes.append([method, needle, list(responses)])

    def request(self, method: str, url: str, *, headers: dict,
                body: bytes | None = None, timeout: float) -> HttpResponse:
        self.calls.append(HttpCall(method, url, dict(headers), body, timeout))
        best = None
        for entry in self._routes:
            rmethod, needle, queue = entry
            if rmethod != method or needle not in url or not queue:
                continue
            if best is None or len(needle) > len(best[1]):
                best = entry
        if best is None:
            raise AssertionError(f"unexpected request: {method} {url}")
        queue = best[2]
        entry = queue.pop(0) if len(queue) > 1 else queue[0]
        return self._materialize(entry, url)

    @staticmethod
    def _materialize(entry, url) -> HttpResponse:
        if isinstance(entry, BaseException):
            raise entry
        if callable(entry):
            return cast(HttpResponse, entry(url))
        if isinstance(entry, HttpResponse):
            return entry
        if isinstance(entry, dict):
            # A bare JSON body defaults to a 200 response.
            return resp(200, entry)
        raise AssertionError(f"unusable scripted response: {entry!r}")

    # -- assertions -------------------------------------------------------- #
    def assert_no_cancel(self, case: unittest.TestCase) -> None:
        for call in self.calls:
            case.assertNotIn(call.method, ("DELETE", "PATCH", "PUT"),
                             f"cancel-like verb {call.method} used for {call.url}")
            case.assertNotIn("cancel", call.url.lower(),
                             f"a cancel endpoint was contacted: {call.url}")

    def starts(self) -> list[HttpCall]:
        return [c for c in self.calls if c.method == "POST" and c.url.endswith("/v1/ciBuildRuns")]

    def urls(self) -> list[str]:
        return [c.url for c in self.calls]


class AdvancingHttp(FakeHttp):
    """A fake that advances a clock by ``step`` before each request, so a test
    can prove the deadline governs preflight as well as polling."""

    def __init__(self, clock: "FakeClock", step: float):
        super().__init__()
        self._clock = clock
        self._step = step

    def request(self, method: str, url: str, *, headers: dict,
                body: bytes | None = None, timeout: float) -> HttpResponse:
        self._clock._monotonic += self._step
        return super().request(method, url, headers=headers, body=body, timeout=timeout)


class FakeClock:
    def __init__(self, wall_start: datetime | None = None):
        self._monotonic = 0.0
        self._wall = wall_start or datetime(2026, 1, 1, tzinfo=timezone.utc)

    def monotonic(self) -> float:
        return self._monotonic

    def utcnow(self) -> datetime:
        return self._wall

    def sleep(self, seconds: float) -> None:
        seconds = max(0.0, seconds)
        self._monotonic += seconds
        self._wall += timedelta(seconds=seconds)


class StubTokenProvider:
    def __init__(self, token: str = "stub-token"):
        self._token = token

    def token(self) -> str:
        return self._token


def resp(status: int, obj=None) -> HttpResponse:
    body = b"" if obj is None else json.dumps(obj).encode("utf-8")
    return HttpResponse(status, {}, body)


# -- workflow + action fixtures (CiAction / CiWorkflow shapes) ---------------- #
def mac_destination(index: int = 0) -> dict:
    return {"deviceTypeName": "Mac", "deviceTypeIdentifier": "mac",
            "runtimeName": "macOS", "runtimeIdentifier": "macos-15", "kind": "MAC"}


def rendercli_action(*, scheme: str = "RenderCLI", platform: str = "MACOS",
                     destinations: int = 1, action_type: str = "TEST") -> dict:
    action = {"name": "Test", "actionType": action_type, "scheme": scheme, "platform": platform}
    if action_type == "TEST":
        action["testConfiguration"] = {
            "kind": "USE_SCHEME_SETTINGS",
            "testDestinations": [mac_destination(i) for i in range(destinations)],
        }
    return action


def archive_action(*, scheme: str = "Nitrate", platform: str = "MACOS") -> dict:
    return {"name": "Archive", "actionType": "ARCHIVE", "scheme": scheme, "platform": platform}


def workflow_data(*, repo_id: str = REPO, product_id: str = PROD, enabled: bool = True,
                  actions=None, **conditions) -> dict:
    attributes = {"name": "Test", "isEnabled": enabled}
    attributes["actions"] = [rendercli_action()] if actions is None else actions
    attributes.update(conditions)
    return {
        "data": {
            "type": "ciWorkflows",
            "id": WID,
            "attributes": attributes,
            "relationships": {
                "repository": {"data": {"type": "scmRepositories", "id": repo_id}},
                "product": {"data": {"type": "ciProducts", "id": product_id}},
            },
        }
    }


def git_refs(*refs, next_link: str | None = None) -> dict:
    payload = {"data": list(refs), "links": {"self": f"{API}/refs"}}
    if next_link:
        payload["links"]["next"] = next_link
    return payload


def git_ref(ref_id: str, name: str, kind: str = "BRANCH", deleted: bool = False) -> dict:
    prefix = "heads" if kind == "BRANCH" else "tags"
    return {
        "type": "scmGitReferences",
        "id": ref_id,
        "attributes": {"name": name, "canonicalName": f"refs/{prefix}/{name}",
                       "kind": kind, "isDeleted": deleted},
    }


def pull_requests(*prs, next_link: str | None = None) -> dict:
    payload = {"data": list(prs), "links": {"self": f"{API}/prs"}}
    if next_link:
        payload["links"]["next"] = next_link
    return payload


def pull_request(pr_id: str, number: int, cross_repo: bool = False) -> dict:
    return {
        "type": "scmPullRequests",
        "id": pr_id,
        "attributes": {"number": number, "isCrossRepository": cross_repo,
                       "sourceBranchName": "feature", "isClosed": False},
    }


def build_runs(*runs, next_link: str | None = None) -> dict:
    payload = {"data": list(runs), "links": {"self": f"{API}/runs"}}
    if next_link:
        payload["links"]["next"] = next_link
    return payload


def run(run_id: str, number: int, progress: str, *, completion=None,
        sha: str | None = None, created: str | None = None) -> dict:
    attributes = {"number": number, "executionProgress": progress}
    if completion is not None:
        attributes["completionStatus"] = completion
    if sha is not None:
        attributes["sourceCommit"] = {"commitSha": sha}
    if created is not None:
        attributes["createdDate"] = created
    return {"type": "ciBuildRuns", "id": run_id, "attributes": attributes}


def build_action(action_id: str, action_type: str = "TEST", name: str = "Test") -> dict:
    return {
        "type": "ciBuildActions",
        "id": action_id,
        "attributes": {"name": name, "actionType": action_type,
                       "executionProgress": "COMPLETE", "completionStatus": "SUCCEEDED",
                       "isRequiredToPass": True},
    }


def build_actions(*actions, next_link: str | None = None) -> dict:
    payload = {"data": list(actions), "links": {"self": f"{API}/actions"}}
    if next_link:
        payload["links"]["next"] = next_link
    return payload


def ci_test_result(status: str = "SUCCESS", name: str = "testSomething") -> dict:
    return {"type": "ciTestResults", "id": f"tr-{name}", "attributes": {
        "className": "SomeTests", "name": name, "status": status,
        "destinationTestResults": [{"uuid": "u", "deviceName": "Mac", "osVersion": "15",
                                    "status": status, "duration": 0.1}]}}


def ci_test_results(*results, next_link: str | None = None) -> dict:
    payload = {"data": list(results), "links": {"self": f"{API}/results"}}
    if next_link:
        payload["links"]["next"] = next_link
    return payload


CREATED = "2026-01-01T00:00:00Z"


# --------------------------------------------------------------------------- #
# Harness
# --------------------------------------------------------------------------- #
class MonitorTestCase(unittest.TestCase):
    def setUp(self):
        self.logs: list[str] = []
        self.tmp = tempfile.TemporaryDirectory(prefix="cloud-monitor-")
        self.addCleanup(self.tmp.cleanup)
        self.summary_path = Path(self.tmp.name) / "summary.md"

    def env(self, **overrides) -> dict:
        env = {
            "APP_STORE_CONNECT_KEY_ID": "KEYID123",
            "APP_STORE_CONNECT_ISSUER_ID": "ISSUER123",
            "APP_STORE_CONNECT_PRIVATE_KEY": "[REDACTED PRIVATE KEY]",
            "XCODE_CLOUD_WORKFLOW_ID": WID,
            "GITHUB_STEP_SUMMARY": str(self.summary_path),
        }
        env.update(overrides)
        return env

    def run_cli(self, http: FakeHttp, clock: FakeClock, *, argv=None, env=None,
                token_provider=None, log=None):
        argv = argv if argv is not None else [
            "start", "--role", "test", "--expected-sha", SHA, "--branch", "main"]
        return cm.main(argv, env or self.env(), http=http, clock=clock,
                       token_provider=token_provider or StubTokenProvider(),
                       log=log or self.logs.append)

    def summary_text(self) -> str:
        return self.summary_path.read_text() if self.summary_path.exists() else ""

    def blob(self) -> str:
        return "\n".join(self.logs) + self.summary_text()

    def happy_http(self, *, actions=None, results=None) -> FakeHttp:
        """A fully scripted happy path: preflight, start, one SUCCEEDED poll, and
        (for the test role) a TEST action with one passing test result."""
        http = FakeHttp()
        http.route("GET", f"/v1/ciProducts/{PROD}/buildRuns", build_runs())
        http.route("GET", f"/v1/scmRepositories/{REPO}/gitReferences",
                   git_refs(git_ref("ref-main", "main")))
        http.route("GET", f"/v1/ciWorkflows/{WID}", workflow_data())
        http.route("POST", "/v1/ciBuildRuns",
                   resp(201, {"data": run(RUN_ID, 42, "PENDING", sha=SHA, created=CREATED)}))
        http.route("GET", f"/v1/ciBuildRuns/{RUN_ID}/actions",
                   actions if actions is not None else build_actions(build_action(TEST_ACTION_ID)))
        http.route("GET", f"/v1/ciBuildActions/{TEST_ACTION_ID}/testResults",
                   results if results is not None else ci_test_results(ci_test_result("SUCCESS")))
        return http


# --------------------------------------------------------------------------- #
# Configuration / credentials -- fail closed, never start
# --------------------------------------------------------------------------- #
class ConfigTests(MonitorTestCase):
    def test_missing_credentials_never_touch_the_network(self):
        http = FakeHttp()
        code = self.run_cli(http, FakeClock(),
                            env=self.env(APP_STORE_CONNECT_PRIVATE_KEY=""))
        self.assertEqual(code, cm.EXIT_CONFIG)
        self.assertEqual(http.calls, [])
        self.assertTrue(any("APP_STORE_CONNECT_PRIVATE_KEY" in line for line in self.logs))

    def test_workflow_id_that_is_a_url_is_rejected(self):
        http = FakeHttp()
        code = self.run_cli(http, FakeClock(),
                            env=self.env(XCODE_CLOUD_WORKFLOW_ID="https://evil.example/x"))
        self.assertEqual(code, cm.EXIT_CONFIG)
        self.assertEqual(http.calls, [])

    def test_malformed_expected_sha_is_rejected(self):
        http = FakeHttp()
        code = self.run_cli(http, FakeClock(),
                            argv=["start", "--workflow-id", WID, "--branch", "main",
                                  "--expected-sha", "not-a-sha"])
        self.assertEqual(code, cm.EXIT_CONFIG)
        self.assertEqual(http.calls, [])

    def test_abbreviated_sha_is_rejected(self):
        # A 7-char abbreviation is not a full commit id: Cloud could build a
        # different commit and only mismatch later, so it is refused up front.
        http = FakeHttp()
        code = self.run_cli(http, FakeClock(),
                            argv=["start", "--workflow-id", WID, "--branch", "main",
                                  "--expected-sha", "abc1234"])
        self.assertEqual(code, cm.EXIT_CONFIG)
        self.assertEqual(http.calls, [])

    def test_whitespace_padded_workflow_id_is_rejected_not_repaired(self):
        http = FakeHttp()
        code = self.run_cli(http, FakeClock(),
                            env=self.env(XCODE_CLOUD_WORKFLOW_ID=f" {WID} "))
        self.assertEqual(code, cm.EXIT_CONFIG)
        self.assertEqual(http.calls, [])

    def test_whitespace_padded_sha_is_rejected_not_repaired(self):
        http = FakeHttp()
        code = self.run_cli(http, FakeClock(),
                            argv=["start", "--workflow-id", WID, "--branch", "main",
                                  "--expected-sha", SHA + " "])
        self.assertEqual(code, cm.EXIT_CONFIG)
        self.assertEqual(http.calls, [])

    def test_non_finite_or_zero_numeric_config_is_rejected(self):
        for bad in ("inf", "nan", "0", "-5"):
            http = FakeHttp()
            code = self.run_cli(http, FakeClock(),
                                argv=["start", "--workflow-id", WID, "--branch", "main",
                                      "--expected-sha", SHA, "--alert-deadline", bad])
            self.assertEqual(code, cm.EXIT_CONFIG, f"deadline {bad!r} was accepted")
            self.assertEqual(http.calls, [])

    def test_branch_and_pull_request_are_mutually_exclusive(self):
        http = FakeHttp()
        code = self.run_cli(http, FakeClock(),
                            argv=["start", "--workflow-id", WID, "--branch", "main",
                                  "--pull-request", "5", "--expected-sha", SHA])
        self.assertEqual(code, cm.EXIT_CONFIG)
        self.assertEqual(http.calls, [])

    def test_http_timeout_is_bounded_and_passed_through(self):
        clock = FakeClock()
        http = self.happy_http()
        http.route("GET", f"/v1/ciBuildRuns/{RUN_ID}",
                   resp(200, {"data": run(RUN_ID, 42, "COMPLETE", completion="SUCCEEDED",
                                          sha=SHA, created=CREATED)}))
        code = self.run_cli(http, clock,
                            argv=["start", "--workflow-id", WID, "--branch", "main",
                                  "--expected-sha", SHA, "--http-timeout", "12"])
        self.assertEqual(code, cm.EXIT_OK)
        self.assertTrue(all(call.timeout == 12.0 for call in http.calls))

    def test_network_timeout_is_clamped_to_the_remaining_deadline(self):
        clock = FakeClock()
        http = self.happy_http()
        http.route("GET", f"/v1/ciBuildRuns/{RUN_ID}",
                   resp(200, {"data": run(RUN_ID, 42, "PENDING", sha=SHA, created=CREATED)}))
        code = self.run_cli(http, clock,
                            argv=["start", "--workflow-id", WID, "--branch", "main",
                                  "--expected-sha", SHA, "--alert-deadline", "100",
                                  "--poll", "30", "--http-timeout", "60"])
        self.assertEqual(code, cm.EXIT_DEADLINE)
        self.assertTrue(all(0 < call.timeout <= 60.0 for call in http.calls))
        # Near the deadline the per-request timeout shrinks below the configured cap.
        self.assertLess(min(call.timeout for call in http.calls), 60.0)


# --------------------------------------------------------------------------- #
# Authentication
# --------------------------------------------------------------------------- #
class AuthTests(MonitorTestCase):
    def test_automatic_condition_detection_is_strict(self):
        present = cm.CloudMonitor._automatic_condition_present
        self.assertFalse(present(None))
        self.assertFalse(present({}))
        self.assertTrue(present({"source": {"isAllMatch": True}}))
        self.assertTrue(present({"schedule": {"frequency": "DAILY"}}))
        # An unrecognised non-empty object still counts as an active trigger.
        self.assertTrue(present({"unexpectedField": 1}))
        # A non-object, non-null value is an unexpected shape and fails closed.
        with self.assertRaises(cm.ShapeError):
            present("nonsense")
        with self.assertRaises(cm.ShapeError):
            present(["x"])

    @unittest.skipUnless(HAVE_CRYPTO, "PyJWT + cryptography are required")
    def test_real_jwt_sign_and_verify_with_an_ephemeral_key(self):
        key = ec.generate_private_key(ec.SECP256R1())
        pem = key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption()).decode()
        clock = FakeClock(datetime.now(timezone.utc))
        provider = cm.JwtTokenProvider("KEYID123", "ISSUER123", pem, clock)
        token = provider.token()

        header = pyjwt.get_unverified_header(token)
        self.assertEqual(header["alg"], "ES256")
        self.assertEqual(header["kid"], "KEYID123")
        claims = pyjwt.decode(token, key.public_key(), algorithms=["ES256"],
                              audience="appstoreconnect-v1", issuer="ISSUER123")
        self.assertEqual(claims["iss"], "ISSUER123")
        self.assertLessEqual(claims["exp"] - claims["iat"], 1200)
        # A second call inside the lifetime reuses the cached token.
        self.assertEqual(provider.token(), token)

    @unittest.skipUnless(HAVE_CRYPTO, "PyJWT + cryptography are required")
    def test_secrets_are_redacted_from_every_log_and_the_summary(self):
        key = ec.generate_private_key(ec.SECP256R1())
        pem = key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption()).decode()
        clock = FakeClock()
        http = self.happy_http()
        http.route("GET", f"/v1/ciBuildRuns/{RUN_ID}",
                   resp(200, {"data": run(RUN_ID, 42, "COMPLETE", completion="SUCCEEDED",
                                          sha=SHA, created=CREATED)}))
        env = self.env(APP_STORE_CONNECT_PRIVATE_KEY=pem)
        code = self.run_cli(http, clock, env=env, token_provider=None)
        self.assertEqual(code, cm.EXIT_OK)

        # The monitor deliberately logs the token and the key to prove redaction.
        redactor = cm.Redactor([pem])
        provider = cm.JwtTokenProvider("KEYID123", "ISSUER123", pem, clock, redactor=redactor)
        monitor = cm.CloudMonitor(config=cm.MonitorConfig(role="test", workflow_id=WID,
                                                          expected_sha=SHA, branch="main"),
                                  http=http, clock=clock, token_provider=provider,
                                  redactor=redactor, log=self.logs.append,
                                  summary=cm.StepSummary(None, self.logs.append))
        monitor.log(f"Bearer {provider.token()}")
        monitor.log(f"key={pem}")

        blob = "\n".join(self.logs) + self.summary_text()
        self.assertNotIn("not-a-real", blob)
        body = pem.strip().splitlines()[1]
        self.assertNotIn(body, blob)
        self.assertNotIn(provider.token(), blob)
        self.assertIn(cm.Redactor.PLACEHOLDER, blob)


# --------------------------------------------------------------------------- #
# Preflight
# --------------------------------------------------------------------------- #
class PreflightTests(MonitorTestCase):
    def test_native_automatic_trigger_refuses_to_start(self):
        http = FakeHttp()
        http.route("GET", f"/v1/ciWorkflows/{WID}",
                   workflow_data(branchStartCondition={"source": {"isAllMatch": True}}))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_PREFLIGHT)
        self.assertEqual(http.starts(), [])
        http.assert_no_cancel(self)

    def test_unknown_automatic_condition_field_is_rejected(self):
        http = FakeHttp()
        http.route("GET", f"/v1/ciWorkflows/{WID}",
                   workflow_data(pullRequestStartCondition={"someNewField": 1}))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_PREFLIGHT)
        self.assertEqual(http.starts(), [])

    def test_unknown_automatic_condition_shape_fails_closed(self):
        http = FakeHttp()
        http.route("GET", f"/v1/ciWorkflows/{WID}",
                   workflow_data(scheduledStartCondition="every day"))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_SHAPE)
        self.assertEqual(http.starts(), [])

    def test_disabled_workflow_refuses_to_start(self):
        http = FakeHttp()
        http.route("GET", f"/v1/ciWorkflows/{WID}", workflow_data(enabled=False))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_PREFLIGHT)
        self.assertEqual(http.starts(), [])

    def test_workflow_without_isEnabled_true_refuses_to_start(self):
        http = FakeHttp()
        payload = workflow_data()
        del payload["data"]["attributes"]["isEnabled"]
        http.route("GET", f"/v1/ciWorkflows/{WID}", payload)
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_PREFLIGHT)
        self.assertEqual(http.starts(), [])

    def test_missing_ref_refuses_to_start(self):
        http = FakeHttp()
        http.route("GET", f"/v1/ciWorkflows/{WID}", workflow_data())
        http.route("GET", f"/v1/scmRepositories/{REPO}/gitReferences",
                   git_refs(git_ref("ref-other", "develop")))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_PREFLIGHT)
        self.assertEqual(http.starts(), [])

    def test_active_runs_across_pagination_refuse_a_new_build(self):
        page1 = build_runs(run("old-1", 7, "RUNNING", sha=SHA),
                           next_link=f"{API}/v1/ciProducts/{PROD}/buildRuns?cursor=2")
        page2 = build_runs(run("old-2", 8, "COMPLETE", completion="SUCCEEDED", sha=SHA))
        http = FakeHttp()
        http.route("GET", f"/v1/ciProducts/{PROD}/buildRuns", page1, page2)
        http.route("GET", f"/v1/scmRepositories/{REPO}/gitReferences",
                   git_refs(git_ref("ref-main", "main")))
        http.route("GET", f"/v1/ciWorkflows/{WID}", workflow_data())
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_ACTIVE)
        self.assertEqual(http.starts(), [])
        http.assert_no_cancel(self)

    def test_active_run_from_another_workflow_in_the_product_refuses(self):
        # The gap: a test monitor timed out but its Cloud run is still going; a
        # release build for a *different* workflow of the same product must still
        # be refused.
        other = run("other-run", 9, "RUNNING", sha=SHA)
        other["relationships"] = {"workflow": {"data": {"type": "ciWorkflows", "id": "other-wf"}}}
        http = FakeHttp()
        http.route("GET", f"/v1/ciWorkflows/{WID}", workflow_data())
        http.route("GET", f"/v1/scmRepositories/{REPO}/gitReferences",
                   git_refs(git_ref("ref-main", "main")))
        http.route("GET", f"/v1/ciProducts/{PROD}/buildRuns", build_runs(other))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_ACTIVE)
        self.assertEqual(http.starts(), [])

    def test_unknown_progress_in_product_runs_fails_closed(self):
        bad = run("weird", 5, "MYSTERY", sha=SHA)
        http = FakeHttp()
        http.route("GET", f"/v1/ciWorkflows/{WID}", workflow_data())
        http.route("GET", f"/v1/scmRepositories/{REPO}/gitReferences",
                   git_refs(git_ref("ref-main", "main")))
        http.route("GET", f"/v1/ciProducts/{PROD}/buildRuns", build_runs(bad))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_SHAPE)
        self.assertEqual(http.starts(), [])

    def test_cross_repository_pull_request_is_rejected(self):
        http = FakeHttp()
        http.route("GET", f"/v1/ciWorkflows/{WID}", workflow_data())
        http.route("GET", f"/v1/scmRepositories/{REPO}/pullRequests",
                   pull_requests(pull_request("pr-9", 9, cross_repo=True)))
        code = self.run_cli(http, FakeClock(),
                            argv=["start", "--workflow-id", WID, "--pull-request", "9",
                                  "--expected-sha", SHA])
        self.assertEqual(code, cm.EXIT_PREFLIGHT)
        self.assertEqual(http.starts(), [])

    def test_preflight_command_validates_without_starting(self):
        http = self.happy_http()
        code = self.run_cli(http, FakeClock(),
                            argv=["preflight", "--workflow-id", WID, "--branch", "main",
                                  "--expected-sha", SHA])
        self.assertEqual(code, cm.EXIT_OK)
        self.assertEqual(http.starts(), [])
        self.assertIn("preflight", self.summary_text())

    def test_workflow_request_explicitly_includes_required_relationships(self):
        http = self.happy_http()
        code = self.run_cli(http, FakeClock(),
                            argv=["preflight", "--workflow-id", WID, "--branch", "main",
                                  "--expected-sha", SHA])
        self.assertEqual(code, cm.EXIT_OK)
        request = next(url for url in http.urls() if f"/ciWorkflows/{WID}" in url)
        self.assertIn("include=product,repository", request)
        self.assertEqual(http.starts(), [])


# --------------------------------------------------------------------------- #
# Role -> action contract (the role must not be a label)
# --------------------------------------------------------------------------- #
class RoleContractTests(MonitorTestCase):
    def preflight(self, http, *, role="test"):
        return self.run_cli(http, FakeClock(),
                            argv=["preflight", "--workflow-id", WID, "--branch", "main",
                                  "--expected-sha", SHA, "--role", role])

    def test_test_role_requires_the_rendercli_test_action(self):
        http = FakeHttp()
        http.route("GET", f"/v1/ciWorkflows/{WID}", workflow_data())
        http.route("GET", f"/v1/scmRepositories/{REPO}/gitReferences",
                   git_refs(git_ref("ref-main", "main")))
        http.route("GET", f"/v1/ciProducts/{PROD}/buildRuns", build_runs())
        self.assertEqual(self.preflight(http), cm.EXIT_OK)
        self.assertEqual(http.starts(), [])

    def test_test_role_rejects_the_wrong_scheme(self):
        http = FakeHttp()
        http.route("GET", f"/v1/ciWorkflows/{WID}",
                   workflow_data(actions=[rendercli_action(scheme="Other")]))
        self.assertEqual(self.preflight(http), cm.EXIT_PREFLIGHT)
        self.assertEqual(http.starts(), [])

    def test_test_role_rejects_the_wrong_platform(self):
        http = FakeHttp()
        http.route("GET", f"/v1/ciWorkflows/{WID}",
                   workflow_data(actions=[rendercli_action(platform="IOS")]))
        self.assertEqual(self.preflight(http), cm.EXIT_PREFLIGHT)
        self.assertEqual(http.starts(), [])

    def test_test_role_rejects_multiple_test_destinations(self):
        http = FakeHttp()
        http.route("GET", f"/v1/ciWorkflows/{WID}",
                   workflow_data(actions=[rendercli_action(destinations=2)]))
        self.assertEqual(self.preflight(http), cm.EXIT_PREFLIGHT)
        self.assertEqual(http.starts(), [])

    def test_test_role_rejects_extra_actions(self):
        http = FakeHttp()
        http.route("GET", f"/v1/ciWorkflows/{WID}",
                   workflow_data(actions=[rendercli_action(), archive_action()]))
        self.assertEqual(self.preflight(http), cm.EXIT_PREFLIGHT)
        self.assertEqual(http.starts(), [])

    def test_test_role_rejects_a_workflow_with_no_actions(self):
        http = FakeHttp()
        http.route("GET", f"/v1/ciWorkflows/{WID}", workflow_data(actions=[]))
        self.assertEqual(self.preflight(http), cm.EXIT_PREFLIGHT)
        self.assertEqual(http.starts(), [])

    def test_test_role_rejects_an_unknown_action_type(self):
        http = FakeHttp()
        http.route("GET", f"/v1/ciWorkflows/{WID}",
                   workflow_data(actions=[{"actionType": "FOO", "scheme": "RenderCLI"}]))
        self.assertEqual(self.preflight(http), cm.EXIT_SHAPE)
        self.assertEqual(http.starts(), [])

    def test_release_role_requires_the_nitrate_archive_action(self):
        http = FakeHttp()
        http.route("GET", f"/v1/ciWorkflows/{WID}", workflow_data(actions=[archive_action()]))
        http.route("GET", f"/v1/scmRepositories/{REPO}/gitReferences",
                   git_refs(git_ref("ref-main", "main")))
        http.route("GET", f"/v1/ciProducts/{PROD}/buildRuns", build_runs())
        self.assertEqual(self.preflight(http, role="release"), cm.EXIT_OK)
        self.assertEqual(http.starts(), [])

    def test_release_role_rejects_a_test_action(self):
        http = FakeHttp()
        http.route("GET", f"/v1/ciWorkflows/{WID}", workflow_data(actions=[rendercli_action()]))
        self.assertEqual(self.preflight(http, role="release"), cm.EXIT_PREFLIGHT)
        self.assertEqual(http.starts(), [])

    def test_release_role_rejects_the_wrong_archive_scheme(self):
        http = FakeHttp()
        http.route("GET", f"/v1/ciWorkflows/{WID}",
                   workflow_data(actions=[archive_action(scheme="SomethingElse")]))
        self.assertEqual(self.preflight(http, role="release"), cm.EXIT_PREFLIGHT)
        self.assertEqual(http.starts(), [])


# --------------------------------------------------------------------------- #
# Start + monitor
# --------------------------------------------------------------------------- #
class MonitorRunTests(MonitorTestCase):
    def test_completed_run_with_exact_sha_passes(self):
        http = self.happy_http()
        http.route("GET", f"/v1/ciBuildRuns/{RUN_ID}",
                   resp(200, {"data": run(RUN_ID, 42, "COMPLETE", completion="SUCCEEDED",
                                          sha=SHA, created=CREATED)}))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_OK)
        self.assertEqual(len(http.starts()), 1)
        http.assert_no_cancel(self)
        self.assertIn("SUCCEEDED", self.summary_text())

    def test_same_repo_pull_request_starts_with_pull_request_relationship(self):
        http = FakeHttp()
        http.route("GET", f"/v1/ciWorkflows/{WID}", workflow_data())
        http.route("GET", f"/v1/scmRepositories/{REPO}/pullRequests",
                   pull_requests(pull_request("pr-7", 7)))
        http.route("GET", f"/v1/ciProducts/{PROD}/buildRuns", build_runs())
        http.route("POST", "/v1/ciBuildRuns",
                   resp(201, {"data": run(RUN_ID, 3, "PENDING", sha=SHA, created=CREATED)}))
        http.route("GET", f"/v1/ciBuildRuns/{RUN_ID}",
                   resp(200, {"data": run(RUN_ID, 3, "COMPLETE", completion="SUCCEEDED",
                                          sha=SHA, created=CREATED)}))
        http.route("GET", f"/v1/ciBuildRuns/{RUN_ID}/actions",
                   build_actions(build_action(TEST_ACTION_ID)))
        http.route("GET", f"/v1/ciBuildActions/{TEST_ACTION_ID}/testResults",
                   ci_test_results(ci_test_result("SUCCESS")))
        code = self.run_cli(http, FakeClock(),
                            argv=["start", "--workflow-id", WID, "--pull-request", "7",
                                  "--expected-sha", SHA])
        self.assertEqual(code, cm.EXIT_OK)
        body = json.loads(http.starts()[0].body)
        relationships = body["data"]["relationships"]
        self.assertEqual(relationships["pullRequest"]["data"]["id"], "pr-7")
        self.assertNotIn("sourceBranchOrTag", relationships)

    def test_stale_source_commit_on_a_completed_run_does_not_request_cancel(self):
        # The run already COMPLETED, so there is nothing left to cancel: only
        # the dedicated source-mismatch alert is emitted, with no unknown-launch
        # or manual-cancel warning for a run that is no longer running.
        http = self.happy_http()
        http.route("GET", f"/v1/ciBuildRuns/{RUN_ID}",
                   resp(200, {"data": run(RUN_ID, 42, "COMPLETE", completion="SUCCEEDED",
                                          sha="deadbeef" * 5, created=CREATED)}))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_SHA_MISMATCH)
        http.assert_no_cancel(self)
        blob = self.blob()
        self.assertEqual("\n".join(self.logs).count("SOURCE COMMIT MISMATCH"), 1)
        self.assertNotIn("OUTCOME UNKNOWN", blob)
        self.assertNotIn("MANUAL CANCEL", blob)

    def test_stale_source_commit_on_an_active_run_emits_one_dedicated_alert(self):
        # The run is still active, so the single dedicated mismatch alert still
        # asks for a manual cancel -- but nothing adds a second, unknown alert.
        http = self.happy_http()
        http.route("GET", f"/v1/ciBuildRuns/{RUN_ID}",
                   resp(200, {"data": run(RUN_ID, 42, "PENDING", sha="deadbeef" * 5,
                                          created=CREATED)}))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_SHA_MISMATCH)
        http.assert_no_cancel(self)
        blob = self.blob()
        self.assertEqual("\n".join(self.logs).count("SOURCE COMMIT MISMATCH"), 1)
        self.assertNotIn("OUTCOME UNKNOWN", blob)
        self.assertIn("MANUAL CANCEL", blob)

    def test_failed_completion_is_a_distinct_failure(self):
        http = self.happy_http()
        http.route("GET", f"/v1/ciBuildRuns/{RUN_ID}",
                   resp(200, {"data": run(RUN_ID, 42, "COMPLETE", completion="FAILED",
                                          sha=SHA, created=CREATED)}))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_BUILD_FAILED)

    def test_canceled_completion_is_a_failure_not_a_pass(self):
        http = self.happy_http()
        http.route("GET", f"/v1/ciBuildRuns/{RUN_ID}",
                   resp(200, {"data": run(RUN_ID, 42, "COMPLETE", completion="CANCELED",
                                          sha=SHA, created=CREATED)}))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_BUILD_FAILED)

    def test_unexpected_shape_fails_closed(self):
        http = self.happy_http()
        http.route("GET", f"/v1/ciBuildRuns/{RUN_ID}",
                   resp(200, {"data": run(RUN_ID, 42, "SOMETHING_ELSE", sha=SHA,
                                          created=CREATED)}))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_SHAPE)

    def test_network_failure_fails_closed(self):
        http = FakeHttp()
        http.route("GET", f"/v1/ciWorkflows/{WID}", cm.NetworkError("dns is down"))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_SHAPE)
        self.assertEqual(http.starts(), [])

    def test_auth_failure_is_reported_and_never_starts(self):
        http = FakeHttp()
        http.route("GET", f"/v1/ciWorkflows/{WID}", resp(401, {"errors": [{"detail": "bad token"}]}))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_AUTH)
        self.assertEqual(http.starts(), [])

    def test_start_failure_is_reported(self):
        http = FakeHttp()
        http.route("GET", f"/v1/ciWorkflows/{WID}", workflow_data())
        http.route("GET", f"/v1/scmRepositories/{REPO}/gitReferences",
                   git_refs(git_ref("ref-main", "main")))
        http.route("GET", f"/v1/ciProducts/{PROD}/buildRuns", build_runs())
        http.route("POST", "/v1/ciBuildRuns", resp(409, {"errors": [{"detail": "conflict"}]}))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_START)
        self.assertEqual(len(http.starts()), 1)


# --------------------------------------------------------------------------- #
# Test-result verification on a SUCCEEDED test run
# --------------------------------------------------------------------------- #
class TestResultVerificationTests(MonitorTestCase):
    def completed(self, http):
        http.route("GET", f"/v1/ciBuildRuns/{RUN_ID}",
                   resp(200, {"data": run(RUN_ID, 42, "COMPLETE", completion="SUCCEEDED",
                                          sha=SHA, created=CREATED)}))
        return http

    def test_succeeded_run_with_a_passing_test_result_passes(self):
        http = self.completed(self.happy_http())
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_OK)
        self.assertIn("Verified 1 test result", self.summary_text())

    def test_succeeded_run_without_a_test_action_is_rejected(self):
        http = self.completed(self.happy_http(
            actions=build_actions(build_action("a1", action_type="BUILD"))))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_TEST_RESULTS)
        self.assertNotIn("passed", self.summary_text())

    def test_succeeded_run_with_zero_test_results_is_rejected(self):
        http = self.completed(self.happy_http(results=ci_test_results()))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_TEST_RESULTS)

    def test_succeeded_run_with_a_failing_test_result_is_rejected(self):
        http = self.completed(self.happy_http(results=ci_test_results(ci_test_result("FAILURE"))))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_TEST_RESULTS)

    def test_succeeded_run_with_a_mixed_test_result_is_rejected(self):
        http = self.completed(self.happy_http(results=ci_test_results(ci_test_result("MIXED"))))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_TEST_RESULTS)

    def test_succeeded_run_reports_skipped_results_rather_than_none(self):
        http = self.completed(self.happy_http(results=ci_test_results(
            ci_test_result("SUCCESS", "executed"), ci_test_result("SKIPPED", "skipped"))))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_OK)
        self.assertIn("1 skipped", self.summary_text())

    def test_succeeded_run_with_only_skipped_results_is_rejected(self):
        http = self.completed(self.happy_http(results=ci_test_results(ci_test_result("SKIPPED"))))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_TEST_RESULTS)
        self.assertNotIn("## Cloud monitor passed", self.summary_text())

    def test_completed_run_with_failing_test_results_is_not_reported_as_unknown_launch(self):
        # A known-COMPLETE run whose tests failed is a definite test-result
        # failure, never an "outcome unknown, a build may be running" alert.
        http = self.completed(self.happy_http(results=ci_test_results(ci_test_result("FAILURE"))))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_TEST_RESULTS)
        blob = self.blob()
        self.assertNotIn("OUTCOME UNKNOWN", blob)
        self.assertNotIn("MANUAL CANCEL", blob)

    def test_completed_run_without_a_source_commit_is_a_plain_failure(self):
        # The run is COMPLETE, so a missing sourceCommit is a plain refusal,
        # not an unknown-launch warning about a possibly-running build.
        http = self.happy_http()
        http.route("GET", f"/v1/ciBuildRuns/{RUN_ID}",
                   resp(200, {"data": run(RUN_ID, 42, "COMPLETE", completion="SUCCEEDED",
                                          created=CREATED)}))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_SHAPE)
        blob = self.blob()
        self.assertNotIn("OUTCOME UNKNOWN", blob)
        self.assertNotIn("MANUAL CANCEL", blob)

    def test_completed_run_with_test_result_network_failure_is_a_plain_failure(self):
        # Completion was already confirmed; a later network failure while
        # reading test results cannot mean the build may still be running.
        http = self.completed(self.happy_http())
        http.route("GET", f"/v1/ciBuildActions/{TEST_ACTION_ID}/testResults?limit=200",
                   cm.NetworkError("connection reset"))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_SHAPE)
        blob = self.blob()
        self.assertNotIn("OUTCOME UNKNOWN", blob)
        self.assertNotIn("MANUAL CANCEL", blob)

    def test_destination_result_failure_rejects_a_green_overall_status(self):
        result = ci_test_result("SUCCESS")
        result["attributes"]["destinationTestResults"][0]["status"] = "FAILURE"
        http = self.completed(self.happy_http(results=ci_test_results(result)))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_TEST_RESULTS)
        self.assertNotIn("## Cloud monitor passed", self.summary_text())

    def test_destination_result_with_unknown_status_fails_closed(self):
        result = ci_test_result("SUCCESS")
        result["attributes"]["destinationTestResults"][0]["status"] = "MYSTERY"
        http = self.completed(self.happy_http(results=ci_test_results(result)))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_SHAPE)

    def test_succeeded_run_with_all_destination_results_skipped_is_rejected(self):
        result = ci_test_result("SUCCESS")
        result["attributes"]["destinationTestResults"][0]["status"] = "SKIPPED"
        http = self.completed(self.happy_http(results=ci_test_results(result)))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_TEST_RESULTS)
        self.assertNotIn("## Cloud monitor passed", self.summary_text())

    def test_unknown_test_status_fails_closed(self):
        http = self.completed(self.happy_http(results=ci_test_results(ci_test_result("MYSTERY"))))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_SHAPE)

    def test_test_results_are_read_across_all_pages(self):
        page1 = ci_test_results(
            ci_test_result("SUCCESS", "a"),
            next_link=f"{API}/v1/ciBuildActions/{TEST_ACTION_ID}/testResults?cursor=2")
        page2 = ci_test_results(ci_test_result("SUCCESS", "b"))
        http = self._paginated_results_http(page1, page2)
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_OK)
        self.assertIn("Verified 2 test result", self.summary_text())

    def test_a_failure_on_a_later_page_is_still_caught(self):
        page1 = ci_test_results(
            ci_test_result("SUCCESS", "a"),
            next_link=f"{API}/v1/ciBuildActions/{TEST_ACTION_ID}/testResults?cursor=2")
        page2 = ci_test_results(ci_test_result("FAILURE", "b"))
        http = self._paginated_results_http(page1, page2)
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_TEST_RESULTS)

    def _paginated_results_http(self, page1, page2) -> FakeHttp:
        http = FakeHttp()
        http.route("GET", f"/v1/ciProducts/{PROD}/buildRuns", build_runs())
        http.route("GET", f"/v1/scmRepositories/{REPO}/gitReferences",
                   git_refs(git_ref("ref-main", "main")))
        http.route("GET", f"/v1/ciWorkflows/{WID}", workflow_data())
        http.route("POST", "/v1/ciBuildRuns",
                   resp(201, {"data": run(RUN_ID, 42, "PENDING", sha=SHA, created=CREATED)}))
        http.route("GET", f"/v1/ciBuildRuns/{RUN_ID}",
                   resp(200, {"data": run(RUN_ID, 42, "COMPLETE", completion="SUCCEEDED",
                                          sha=SHA, created=CREATED)}))
        http.route("GET", f"/v1/ciBuildRuns/{RUN_ID}/actions",
                   build_actions(build_action(TEST_ACTION_ID)))
        http.route("GET", f"/v1/ciBuildActions/{TEST_ACTION_ID}/testResults", page1, page2)
        return http

    def test_release_role_does_not_require_test_results(self):
        http = FakeHttp()
        http.route("GET", f"/v1/ciWorkflows/{WID}", workflow_data(actions=[archive_action()]))
        http.route("GET", f"/v1/scmRepositories/{REPO}/gitReferences",
                   git_refs(git_ref("ref-main", "main")))
        http.route("GET", f"/v1/ciProducts/{PROD}/buildRuns", build_runs())
        http.route("POST", "/v1/ciBuildRuns",
                   resp(201, {"data": run(RUN_ID, 42, "PENDING", sha=SHA, created=CREATED)}))
        http.route("GET", f"/v1/ciBuildRuns/{RUN_ID}",
                   resp(200, {"data": run(RUN_ID, 42, "COMPLETE", completion="SUCCEEDED",
                                          sha=SHA, created=CREATED)}))
        code = self.run_cli(http, FakeClock(),
                            argv=["start", "--workflow-id", WID, "--branch", "main",
                                  "--expected-sha", SHA, "--role", "release"])
        self.assertEqual(code, cm.EXIT_OK)
        # No ciBuildRuns/{id}/actions request is made for the release role.
        self.assertTrue(all("/actions" not in url for url in http.urls()))


# --------------------------------------------------------------------------- #
# Launch-outcome uncertainty (a POST may have created a run we cannot see)
# --------------------------------------------------------------------------- #
class LaunchUncertaintyTests(MonitorTestCase):
    def preflight_http(self) -> FakeHttp:
        http = FakeHttp()
        http.route("GET", f"/v1/ciWorkflows/{WID}", workflow_data())
        http.route("GET", f"/v1/scmRepositories/{REPO}/gitReferences",
                   git_refs(git_ref("ref-main", "main")))
        http.route("GET", f"/v1/ciProducts/{PROD}/buildRuns", build_runs())
        return http

    def test_post_network_failure_warns_about_a_possible_launch(self):
        http = self.preflight_http()
        http.route("POST", "/v1/ciBuildRuns", cm.NetworkError("connection reset"))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_START)
        self.assertEqual(len(http.starts()), 1)  # never retried
        http.assert_no_cancel(self)
        blob = self.blob()
        self.assertIn("OUTCOME UNKNOWN", blob)
        self.assertIn(WID, blob)

    def test_start_response_without_an_id_warns(self):
        http = self.preflight_http()
        http.route("POST", "/v1/ciBuildRuns", resp(201, {"data": {"type": "ciBuildRuns"}}))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_START)
        self.assertIn("OUTCOME UNKNOWN", self.blob())
        self.assertIn(WID, self.blob())

    def test_start_response_that_is_not_json_warns(self):
        http = self.preflight_http()
        http.route("POST", "/v1/ciBuildRuns", HttpResponse(201, {}, b"not json at all"))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_START)
        self.assertIn("OUTCOME UNKNOWN", self.blob())

    def test_poll_failure_reports_the_known_run_id(self):
        http = self.happy_http()
        http.route("GET", f"/v1/ciBuildRuns/{RUN_ID}", cm.NetworkError("reset"))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_SHAPE)
        blob = self.blob()
        self.assertIn("OUTCOME UNKNOWN", blob)
        self.assertIn(RUN_ID, blob)

    def test_config_failure_never_claims_a_launch(self):
        http = FakeHttp()
        code = self.run_cli(http, FakeClock(),
                            env=self.env(APP_STORE_CONNECT_PRIVATE_KEY=""))
        self.assertEqual(code, cm.EXIT_CONFIG)
        blob = self.blob()
        self.assertNotIn("OUTCOME UNKNOWN", blob)
        self.assertNotIn("MAY BE RUNNING", blob)
        self.assertNotIn("MAY STILL BE RUNNING", blob)

    def test_preflight_refusal_never_claims_a_launch(self):
        http = FakeHttp()
        http.route("GET", f"/v1/ciWorkflows/{WID}", workflow_data(enabled=False))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_PREFLIGHT)
        blob = self.blob()
        self.assertNotIn("OUTCOME UNKNOWN", blob)
        self.assertNotIn("MAY BE RUNNING", blob)


# --------------------------------------------------------------------------- #
# The deadline governs preflight too
# --------------------------------------------------------------------------- #
class PreflightDeadlineTests(MonitorTestCase):
    def test_expired_deadline_during_preflight_refuses_to_start(self):
        clock = FakeClock()
        http = AdvancingHttp(clock, step=100.0)
        http.route("GET", f"/v1/ciWorkflows/{WID}", workflow_data())
        http.route("GET", f"/v1/scmRepositories/{REPO}/gitReferences",
                   git_refs(git_ref("ref-main", "main")))
        http.route("GET", f"/v1/ciProducts/{PROD}/buildRuns", build_runs())
        code = self.run_cli(http, clock,
                            argv=["start", "--workflow-id", WID, "--branch", "main",
                                  "--expected-sha", SHA, "--alert-deadline", "1"])
        self.assertEqual(code, cm.EXIT_DEADLINE)
        self.assertEqual(http.starts(), [])
        self.assertNotIn("OUTCOME UNKNOWN", self.blob())


# --------------------------------------------------------------------------- #
# SSRF / redirect hardening
# --------------------------------------------------------------------------- #
class UrlSecurityTests(MonitorTestCase):
    def test_api_url_validation_accepts_only_the_exact_https_host(self):
        good = f"{API}/v1/ciWorkflows/{WID}"
        cm.validate_api_url(good, cm.APPLE_API_HOST)
        cm.validate_api_url(f"{API}:443/v1/ciWorkflows/{WID}", cm.APPLE_API_HOST)
        for bad in (
            "http://api.appstoreconnect.apple.com/v1/x",
            "https://evil.example/v1/x",
            "https://api.appstoreconnect.apple.com.evil.example/v1/x",
            "https://user@api.appstoreconnect.apple.com/v1/x",
            "https://api.appstoreconnect.apple.com:8443/v1/x",
            "/v1/ciWorkflows/x",
            "",
        ):
            with self.assertRaises(cm.ShapeError, msg=f"accepted {bad!r}"):
                cm.validate_api_url(bad, cm.APPLE_API_HOST)

    def test_http_client_refuses_to_follow_redirects(self):
        handler = cm._RefuseRedirects()
        request = urllib.request.Request(f"{API}/v1/ciBuildRuns")
        with self.assertRaises(urllib.error.HTTPError):
            handler.redirect_request(request, None, 302, "Found", {},
                                     "https://evil.example/steal?token=1")

    def test_malicious_pagination_next_link_is_refused_without_a_request(self):
        http = FakeHttp()
        http.route("GET", f"/v1/ciWorkflows/{WID}", workflow_data())
        http.route("GET", f"/v1/scmRepositories/{REPO}/gitReferences",
                   git_refs(git_ref("ref-main", "main"),
                            next_link="https://evil.example/steal?token=1"))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_SHAPE)
        self.assertEqual(http.starts(), [])
        # The foreign host is never contacted, so no Bearer token is ever sent.
        self.assertTrue(all("evil.example" not in url for url in http.urls()))
        self.assertTrue(all(url.startswith(API) for url in http.urls()))

    def test_redirect_status_is_not_followed_by_the_monitor(self):
        http = FakeHttp()
        http.route("GET", f"/v1/ciWorkflows/{WID}", workflow_data())
        http.route("GET", f"/v1/scmRepositories/{REPO}/gitReferences",
                   git_refs(git_ref("ref-main", "main")))
        http.route("GET", f"/v1/ciProducts/{PROD}/buildRuns", build_runs())
        http.route("POST", "/v1/ciBuildRuns", resp(302, {}))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_START)
        # Only the API host was contacted; nothing was re-issued to a redirect target.
        self.assertTrue(all(url.startswith(API) for url in http.urls()))


# --------------------------------------------------------------------------- #
# The 600 s alert deadline -- never cancels
# --------------------------------------------------------------------------- #
class DeadlineTests(MonitorTestCase):
    def queued_http(self) -> FakeHttp:
        http = self.happy_http()
        http.route("GET", f"/v1/ciBuildRuns/{RUN_ID}",
                   resp(200, {"data": run(RUN_ID, 42, "PENDING", sha=SHA, created=CREATED)}))
        return http

    def test_queued_run_alerts_without_compute_and_never_cancels(self):
        http = self.queued_http()
        clock = FakeClock()
        code = self.run_cli(http, clock,
                            argv=["start", "--workflow-id", WID, "--branch", "main",
                                  "--expected-sha", SHA, "--alert-deadline", "600",
                                  "--poll", "30"])
        self.assertEqual(code, cm.EXIT_DEADLINE)
        http.assert_no_cancel(self)
        blob = self.blob()
        self.assertIn("CLOUD MAY STILL BE RUNNING", blob)
        self.assertIn("MANUAL CANCEL REQUIRED", blob)
        self.assertIn(RUN_ID, blob)
        self.assertIn("42", blob)
        # The clock advanced only through bounded sleeps and stopped at the cap.
        self.assertGreaterEqual(clock.monotonic(), 600)
        self.assertLess(clock.monotonic(), 660)

    def test_alert_comment_permission_denied_still_fails_the_monitor(self):
        http = self.queued_http()
        http.route("GET", "api.github.com/repos/o/r/issues/12/comments", resp(200, []))
        http.route("POST", "api.github.com/repos/o/r/issues/12/comments", resp(403, {"message": "no"}))
        env = self.env(GITHUB_TOKEN="ghs_fake", GITHUB_REPOSITORY="o/r")
        code = self.run_cli(http, FakeClock(),
                            argv=["start", "--workflow-id", WID, "--branch", "main",
                                  "--expected-sha", SHA, "--alert-pr", "12"],
                            env=env)
        self.assertEqual(code, cm.EXIT_DEADLINE)
        self.assertTrue(any("rejected" in line for line in self.logs))

    def test_alert_comment_is_posted_once_and_deduplicated(self):
        http = self.queued_http()
        http.route("GET", "api.github.com/repos/o/r/issues/12/comments", resp(200, []))
        http.route("POST", "api.github.com/repos/o/r/issues/12/comments",
                   resp(201, {"id": 1}))
        env = self.env(GITHUB_TOKEN="ghs_fake", GITHUB_REPOSITORY="o/r")
        code = self.run_cli(http, FakeClock(),
                            argv=["start", "--workflow-id", WID, "--branch", "main",
                                  "--expected-sha", SHA, "--alert-pr", "12"],
                            env=env)
        self.assertEqual(code, cm.EXIT_DEADLINE)
        posts = [c for c in http.calls if c.method == "POST" and "api.github.com" in c.url]
        self.assertEqual(len(posts), 1)
        # The token must never be written into the comment body or a log line.
        self.assertNotIn("ghs_fake", posts[0].body.decode())
        self.assertNotIn("ghs_fake", "\n".join(self.logs))

    def test_existing_comment_prevents_a_duplicate(self):
        http = self.queued_http()
        marker = f"<!-- cloud-monitor-alert:deadline:{RUN_ID} -->"
        http.route("GET", "api.github.com/repos/o/r/issues/12/comments",
                   resp(200, [{"body": marker}]))
        env = self.env(GITHUB_TOKEN="ghs_fake", GITHUB_REPOSITORY="o/r")
        code = self.run_cli(http, FakeClock(),
                            argv=["start", "--workflow-id", WID, "--branch", "main",
                                  "--expected-sha", SHA, "--alert-pr", "12"],
                            env=env)
        self.assertEqual(code, cm.EXIT_DEADLINE)
        posts = [c for c in http.calls if c.method == "POST" and "api.github.com" in c.url]
        self.assertEqual(posts, [])

    def test_interrupt_warns_that_the_cloud_run_may_still_be_running(self):
        http = self.happy_http()
        # The first poll raises the interrupt that the signal handler raises.
        http.route("GET", f"/v1/ciBuildRuns/{RUN_ID}", cm.Interrupted("signal"))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_INTERRUPTED)
        blob = self.blob()
        self.assertIn("MAY STILL BE RUNNING", blob)
        self.assertIn("manually", blob.lower())
        http.assert_no_cancel(self)

    def test_interrupt_after_completion_does_not_claim_the_run_is_running(self):
        # The run reached COMPLETE before the interrupt, so nothing is running.
        http = self.happy_http()
        http.route("GET", f"/v1/ciBuildRuns/{RUN_ID}",
                   resp(200, {"data": run(RUN_ID, 42, "COMPLETE", completion="SUCCEEDED",
                                          sha=SHA, created=CREATED)}))
        http.route("GET", f"/v1/ciBuildRuns/{RUN_ID}/actions?limit=200", cm.Interrupted("signal"))
        code = self.run_cli(http, FakeClock())
        self.assertEqual(code, cm.EXIT_INTERRUPTED)
        blob = self.blob()
        self.assertNotIn("MAY STILL BE RUNNING", blob)
        self.assertNotIn("MANUAL CANCEL", blob)
        http.assert_no_cancel(self)


# --------------------------------------------------------------------------- #
# Static workflow contracts (not a claim that GitHub dispatched a run)
# --------------------------------------------------------------------------- #
class ReleaseWorkflowContractTests(unittest.TestCase):
    """cloud.yml is now the manual-only RELEASE monitor.

    The automatic TEST monitor moved to xcode.yml; the duplicate manual test
    launcher was removed so a human cannot start a second, unmonitored test build
    that contends for the same product compute.
    """

    def setUp(self):
        self.assertTrue(WORKFLOW.is_file(), "cloud monitor workflow is missing")
        self.text = WORKFLOW.read_text()

    def test_dispatch_only_during_cutover(self):
        self.assertIn("workflow_dispatch:", self.text)
        # Automatic triggers must be commented out, not active.
        self.assertNotIn("\n  pull_request:", self.text)
        self.assertNotIn("\n  push:", self.text)
        self.assertNotIn("pull_request_target:", self.text)
        self.assertIn("#  pull_request:", self.text)

    def test_only_the_release_job_remains(self):
        # The manual TEST launcher is gone; xcode.yml owns the test role now.
        self.assertIn("main-archive:", self.text)
        self.assertNotIn("pr-test:", self.text)
        self.assertEqual(self.text.count("runs-on: ubuntu-latest"), 1)
        self.assertEqual(self.text.count("timeout-minutes: 15"), 1)

    def test_permissions_and_concurrency_are_conservative(self):
        self.assertIn("permissions:\n  contents: read\n  pull-requests: write", self.text)
        self.assertNotIn(": admin", self.text)
        self.assertIn("cancel-in-progress: false", self.text)
        self.assertIn("group: cloud-monitor", self.text)

    def test_release_workflow_id_comes_from_a_repo_variable(self):
        self.assertIn("vars.XCODE_CLOUD_RELEASE_WORKFLOW_ID", self.text)

    def test_checkout_is_pinned_and_read_only(self):
        self.assertIn("actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5", self.text)
        self.assertEqual(self.text.count("persist-credentials: false"), 1)

    def test_secrets_are_env_only_and_never_shell_interpolated(self):
        self.assertIn("secrets.APP_STORE_CONNECT_KEY_ID", self.text)
        self.assertIn("secrets.APP_STORE_CONNECT_PRIVATE_KEY", self.text)
        for line in self.text.splitlines():
            if line.strip().startswith("run:"):
                self.assertNotIn("${{", line)
            if "${{" in line and "secrets." in line:
                self.assertIn("env:", self.text)
                self.assertTrue(line.strip().startswith(("APP_STORE", "GITHUB", "XCODE")),
                                f"secret interpolated outside env: {line}")

    def test_private_key_is_scoped_to_the_start_step_only(self):
        # The App Store Connect private key must not be in a job-level env block
        # (which would expose it to dependency install and unit-test steps). It is
        # declared once per job, inside the start step's env.
        key_lines = [line for line in self.text.splitlines()
                     if "APP_STORE_CONNECT_PRIVATE_KEY" in line]
        self.assertEqual(len(key_lines), 1)
        for line in key_lines:
            indent = len(line) - len(line.lstrip())
            self.assertEqual(indent, 10, f"private key not scoped to a step env: {line!r}")
        for line in self.text.splitlines():
            if "APP_STORE_CONNECT_KEY_ID:" in line:
                indent = len(line) - len(line.lstrip())
                self.assertEqual(indent, 6, f"key id not in the job env: {line!r}")

    def test_no_global_installs_and_no_pushes(self):
        self.assertNotIn("pip install ", self.text)
        self.assertIn("--require-hashes", self.text)
        self.assertIn("scripts/cloud_monitor.py", self.text)
        self.assertIn("scripts/test_cloud_monitor.py", self.text)
        self.assertNotIn("git push", self.text)
        self.assertNotIn("sudo ", self.text)


class TestMonitorWorkflowContractTests(unittest.TestCase):
    """xcode.yml is the automatic test monitor that keeps the required check.

    It replaces the native macOS job: same required status context
    ("Xcode build and tests"), but an Ubuntu job that orchestrates and monitors a
    Cloud RenderCLI TEST run. It must fail forks, build the PR head branch with
    --branch, and pin the helper to the reviewed commit.
    """

    def setUp(self):
        self.assertTrue(TEST_WORKFLOW.is_file(), "the test monitor workflow is missing")
        self.text = TEST_WORKFLOW.read_text()

    def test_triggers_on_pr_and_dispatch_without_racing_testflight(self):
        self.assertIn("pull_request:", self.text)
        self.assertIn("branches: [main]", self.text)
        self.assertNotIn("\n  push:", self.text)
        self.assertIn("workflow_dispatch:", self.text)
        self.assertNotIn("pull_request_target:", self.text)

    def test_preserves_the_required_check_context(self):
        # The required main-branch status check name must not change.
        self.assertIn("name: Xcode build and tests", self.text)

    def test_runs_on_ubuntu_not_a_macos_runner(self):
        self.assertIn("runs-on: ubuntu-latest", self.text)
        self.assertIn("timeout-minutes: 15", self.text)
        self.assertNotIn("xcode-27", self.text)

    def test_concurrency_matches_the_product_wide_monitor_group(self):
        self.assertIn("group: cloud-monitor", self.text)
        self.assertIn("cancel-in-progress: false", self.text)

    def test_helper_is_pinned_to_the_reviewed_commit_not_the_pr_head(self):
        self.assertIn("actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5", self.text)
        self.assertIn("ref: 05993dd3ef90ff19d38440a49cc462f8f5ead2c3", self.text)
        self.assertIn("persist-credentials: false", self.text)

    def test_fork_pull_requests_fail_instead_of_passing(self):
        # A fork must fail the check, never pass by being skipped, and must not
        # expose credentials.
        self.assertIn("github.event.pull_request.head.repo.full_name != github.repository",
                      self.text)
        self.assertIn("exit 1", self.text)

    def test_builds_the_head_branch_with_branch_not_pull_request(self):
        self.assertIn("--branch", self.text)
        self.assertNotIn("--pull-request", self.text)

    def test_workflow_id_comes_from_the_repo_variable(self):
        self.assertIn("vars.XCODE_CLOUD_TEST_WORKFLOW_ID", self.text)

    def test_private_key_is_scoped_to_the_start_step_only(self):
        key_lines = [line for line in self.text.splitlines()
                     if "APP_STORE_CONNECT_PRIVATE_KEY" in line]
        self.assertEqual(len(key_lines), 1)
        for line in key_lines:
            indent = len(line) - len(line.lstrip())
            self.assertEqual(indent, 10, f"private key not scoped to a step env: {line!r}")

    def test_dependencies_are_hash_pinned_and_unit_tests_run(self):
        self.assertIn("--require-hashes", self.text)
        self.assertNotIn("pip install ", self.text)
        self.assertIn("scripts/cloud-monitor-requirements.txt", self.text)
        self.assertIn("scripts/test_cloud_monitor.py", self.text)
        self.assertIn("scripts/cloud_monitor.py", self.text)
        self.assertNotIn("git push", self.text)
        self.assertNotIn("sudo ", self.text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
