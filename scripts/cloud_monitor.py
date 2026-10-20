#!/usr/bin/env python3
"""Start and monitor an Xcode Cloud build run through the App Store Connect API.

Contract resolved from the official App Store Connect OpenAPI specification,
version 4.5.1 (``info.version == "4.5.1"``), downloaded from
https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip
and parsed directly. Only the endpoints this CLI needs are used:

  POST /v1/ciBuildRuns                        -> start a build run (the only write verb)
  GET  /v1/ciBuildRuns/{id}                   -> read one run (poll)
  GET  /v1/ciWorkflows/{id}                   -> workflow + actions + native start conditions
  GET  /v1/ciProducts/{id}/buildRuns          -> preflight active runs for the whole product
  GET  /v1/ciBuildRuns/{id}/actions           -> the actions a run performed (find the TEST action)
  GET  /v1/ciBuildActions/{id}/testResults    -> the test results of a TEST action (paginated)
  GET  /v1/scmRepositories/{id}/gitReferences -> resolve an exact branch/tag ref
  GET  /v1/scmRepositories/{id}/pullRequests  -> resolve a same-repo pull request

Two facts drive the whole design and are verified against that spec:

* ``/v1/ciBuildRuns`` is **POST only**; ``/v1/ciBuildRuns/{id}`` is **GET only**.
  0 of 1303 ``operationId`` values contain "cancel" and no ``DELETE``/``PATCH``
  exists on any build-run path. **There is no cancel endpoint.**
* No resource exposes a ``timeout``/``maxDuration`` field, so a 600 s cap cannot
  be declared to Apple. The cap is enforced here, client side, as an **alert
  deadline**: when it is exceeded this CLI reports a distinct failure and prints
  a loud manual-cancellation notice. It **never** calls a cancel endpoint.

Auth is a short-lived ES256 JWT (PyJWT + cryptography). All HTTP goes through an
injectable client so tests can drive scripted responses; the production path uses
``urllib``. Nothing here is simulated in production: every call is a real request.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import signal
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Callable, Optional, Protocol
from urllib.parse import urlsplit

API_BASE = "https://api.appstoreconnect.apple.com"
GITHUB_API_BASE = "https://api.github.com"
# The only hosts this CLI is ever allowed to contact. Every request URL is
# checked against exactly one of these before a socket is opened.
APPLE_API_HOST = "api.appstoreconnect.apple.com"
GITHUB_API_HOST = "api.github.com"
JWT_AUDIENCE = "appstoreconnect-v1"
JWT_LIFETIME_SECONDS = 1200  # Apple allows at most 20 minutes.
TOKEN_REFRESH_MARGIN_SECONDS = 60
DEFAULT_ALERT_DEADLINE_SECONDS = 600.0
DEFAULT_POLL_SECONDS = 20.0
DEFAULT_HTTP_TIMEOUT_SECONDS = 30.0
MAX_PAGES = 50  # Bound pagination so a malformed cursor chain cannot loop forever.

# Distinct, documented exit codes. Every failure path is closed: a missing
# credential, an unverifiable shape, or an exceeded deadline is a non-zero exit.
EXIT_OK = 0
EXIT_USAGE = 2           # bad CLI arguments
EXIT_CONFIG = 3          # missing credentials/config -> never start
EXIT_AUTH = 4            # authentication / permission failure
EXIT_PREFLIGHT = 5       # workflow/ref/start-condition problem -> refuse to start
EXIT_ACTIVE = 6          # an active run already exists -> refuse a new build
EXIT_START = 7           # the start (POST) call failed
EXIT_SHAPE = 8           # unexpected API shape / network failure (fail closed)
EXIT_SHA_MISMATCH = 9    # sourceCommit mismatch -> Cloud manual cancel needed
EXIT_BUILD_FAILED = 10   # run completed but not SUCCEEDED
EXIT_DEADLINE = 11       # alert deadline exceeded -> CLOUD MAY STILL BE RUNNING
EXIT_TEST_RESULTS = 12   # SUCCEEDED but test results missing/failed -> refuse green
EXIT_INTERRUPTED = 130   # interrupted -> warn about manual cancellation

# Native start conditions that would launch an unmonitored build. Every launch
# must go through this monitor, so these must all be absent/null/empty.
AUTOMATIC_START_CONDITIONS = (
    "branchStartCondition",
    "tagStartCondition",
    "pullRequestStartCondition",
    "scheduledStartCondition",
)
MANUAL_START_CONDITIONS = (
    "manualBranchStartCondition",
    "manualTagStartCondition",
    "manualPullRequestStartCondition",
)

# Verbatim enums from the App Store Connect OpenAPI 4.5.1 spec.
CI_ACTION_TYPES = ("BUILD", "ANALYZE", "TEST", "ARCHIVE")
CI_ACTION_PLATFORMS = ("MACOS", "IOS", "TVOS", "WATCHOS", "VISIONOS")
CI_TEST_STATUSES = ("SUCCESS", "FAILURE", "MIXED", "SKIPPED", "EXPECTED_FAILURE")
CI_EXECUTION_PROGRESS = ("PENDING", "RUNNING", "COMPLETE")
# A test result that must never be accepted as a green test run.
CI_TEST_FAILING_STATUSES = ("FAILURE", "MIXED")

# The action each role's workflow must declare, and nothing else. The reviewer
# fixed the contract to one compute-spending action per role: a TEST action with
# the RenderCLI scheme on the MACOS platform and exactly one test destination for
# the test workflow; an ARCHIVE action with the Nitrate scheme for the release
# workflow. Any additional action is rejected because it spends extra compute.
ROLE_ACTION_CONTRACT = {
    "test": {"actionType": "TEST", "scheme": "RenderCLI", "platform": "MACOS",
             "require_single_destination": True},
    "release": {"actionType": "ARCHIVE", "scheme": "Nitrate", "platform": None,
                "require_single_destination": False},
}

WORKFLOW_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{0,63}$")

SECRET_ENV_NAMES = (
    "APP_STORE_CONNECT_KEY_ID",
    "APP_STORE_CONNECT_ISSUER_ID",
    "APP_STORE_CONNECT_PRIVATE_KEY",
    "GITHUB_TOKEN",
)


# --------------------------------------------------------------------------- #
# Errors
# --------------------------------------------------------------------------- #
class MonitorError(Exception):
    """Base class; ``exit_code`` drives the process result."""

    exit_code = EXIT_SHAPE


class UsageError(MonitorError):
    exit_code = EXIT_USAGE


class ConfigError(MonitorError):
    exit_code = EXIT_CONFIG


class AuthError(MonitorError):
    exit_code = EXIT_AUTH


class PreflightError(MonitorError):
    exit_code = EXIT_PREFLIGHT


class ActiveBuildError(MonitorError):
    exit_code = EXIT_ACTIVE


class StartError(MonitorError):
    exit_code = EXIT_START


class ShapeError(MonitorError):
    exit_code = EXIT_SHAPE


class NetworkError(MonitorError):
    exit_code = EXIT_SHAPE


class ApiError(MonitorError):
    def __init__(self, message: str, *, status: Optional[int] = None):
        super().__init__(message)
        self.status = status
        self.exit_code = EXIT_AUTH if status in (401, 403) else EXIT_SHAPE


class SourceCommitMismatch(MonitorError):
    exit_code = EXIT_SHA_MISMATCH


class DeadlineExceeded(MonitorError):
    exit_code = EXIT_DEADLINE


class TestResultError(MonitorError):
    exit_code = EXIT_TEST_RESULTS


class Interrupted(MonitorError):
    exit_code = EXIT_INTERRUPTED


# --------------------------------------------------------------------------- #
# Redaction
# --------------------------------------------------------------------------- #
class Redactor:
    """Removes secret material from any text before it is logged or summarised."""

    PLACEHOLDER = "***REDACTED***"

    def __init__(self, secrets: Optional[list[str]] = None):
        self._secrets: list[str] = []
        for secret in secrets or []:
            self.add(secret)

    def add(self, secret: Optional[str]) -> None:
        if not secret:
            return
        secret = secret.strip()
        if len(secret) < 8:
            return
        if secret not in self._secrets:
            self._secrets.append(secret)
        # A PEM private key is one multi-line string, but its base64 body can
        # also leak on its own; redact each long line too.
        if "\n" in secret:
            for line in secret.splitlines():
                line = line.strip()
                if len(line) >= 24 and line not in self._secrets:
                    self._secrets.append(line)

    def __call__(self, text: str) -> str:
        if not isinstance(text, str):
            text = str(text)
        for secret in self._secrets:
            if secret in text:
                text = text.replace(secret, self.PLACEHOLDER)
        return text


# --------------------------------------------------------------------------- #
# Clock
# --------------------------------------------------------------------------- #
class Clock(Protocol):
    def monotonic(self) -> float: ...

    def utcnow(self) -> datetime: ...

    def sleep(self, seconds: float) -> None: ...


class SystemClock:
    def monotonic(self) -> float:
        return time.monotonic()

    def utcnow(self) -> datetime:
        return datetime.now(timezone.utc)

    def sleep(self, seconds: float) -> None:
        if seconds > 0:
            time.sleep(seconds)


# --------------------------------------------------------------------------- #
# HTTP
# --------------------------------------------------------------------------- #
@dataclass
class HttpResponse:
    status: int
    headers: dict
    body: bytes

    def json(self) -> object:
        if not self.body:
            raise ShapeError(f"empty response body (status {self.status})")
        try:
            return json.loads(self.body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ShapeError(f"response body was not JSON (status {self.status}): {error}")


class HttpClient(Protocol):
    def request(self, method: str, url: str, *, headers: dict,
                body: Optional[bytes] = None, timeout: float) -> HttpResponse: ...


def validate_api_url(url: str, allowed_host: str) -> None:
    """Refuse any URL that is not exactly HTTPS on ``allowed_host``.

    A pagination ``links.next`` value is attacker-influenced if a response is
    ever tampered with, and a redirect could forward the Apple JWT to a foreign
    host. Every request URL therefore has to be an absolute HTTPS URL on the
    single expected host, with no userinfo and no non-443 port. Anything else
    (a relative path, a foreign host, an ``http://`` URL, ``user@host``) fails
    closed before a socket is opened.
    """
    if not isinstance(url, str) or not url:
        raise ShapeError("refusing a non-string or empty API URL")
    parts = urlsplit(url)
    if parts.scheme != "https":
        raise ShapeError(f"refusing a non-HTTPS API URL: {url!r}")
    if parts.username is not None or parts.password is not None or "@" in parts.netloc:
        raise ShapeError(f"refusing an API URL carrying userinfo: {url!r}")
    if parts.hostname != allowed_host:
        raise ShapeError(f"refusing an API URL for a foreign host: {url!r}")
    if parts.port not in (None, 443):
        raise ShapeError(f"refusing an API URL on a non-443 port: {url!r}")
    if not parts.path.startswith("/") or parts.path.startswith("//"):
        raise ShapeError(f"refusing an API URL with a non-absolute path: {url!r}")


class _RefuseRedirects(urllib.request.HTTPRedirectHandler):
    """Never follow a redirect, so an Authorization header can never be
    forwarded to a host Apple (or GitHub) did not name."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(
            req.full_url, code,
            f"refusing to follow a redirect to {newurl!r}", headers, fp)


class UrllibHttpClient:
    """Real HTTP transport. HTTP status errors are returned, not raised, so
    callers can distinguish 401/403/404 from a transport failure. Redirects are
    refused outright: a 30x is surfaced as its status, and the request is never
    re-issued against the redirect target."""

    def __init__(self):
        self._opener = urllib.request.build_opener(_RefuseRedirects())

    def request(self, method: str, url: str, *, headers: dict,
                body: Optional[bytes] = None, timeout: float) -> HttpResponse:
        request = urllib.request.Request(url, data=body, method=method)
        for key, value in headers.items():
            request.add_header(key, value)
        try:
            with self._opener.open(request, timeout=timeout) as response:
                return HttpResponse(response.status, dict(response.headers), response.read())
        except urllib.error.HTTPError as error:
            payload = b""
            try:
                payload = error.read()
            except Exception:  # pragma: no cover - defensive
                payload = b""
            return HttpResponse(error.code, dict(error.headers or {}), payload)
        except urllib.error.URLError as error:
            raise NetworkError(f"network failure for {method} {url}: {error.reason}")
        except OSError as error:
            raise NetworkError(f"network failure for {method} {url}: {error}")


# --------------------------------------------------------------------------- #
# Auth
# --------------------------------------------------------------------------- #
class TokenProvider(Protocol):
    def token(self) -> str: ...


class JwtTokenProvider:
    """ES256 App Store Connect API token using PyJWT + cryptography.

    The private key is a ``.p8`` PEM supplied through an environment variable;
    it is never written to logs, argv, or the step summary.
    """

    def __init__(self, key_id: str, issuer_id: str, private_key: str,
                 clock: Clock, *, redactor: Optional[Redactor] = None):
        if not key_id or not issuer_id or not private_key:
            raise ConfigError("App Store Connect key id, issuer id and private key are all required")
        try:
            import jwt  # noqa: F401  (PyJWT)
        except ImportError as error:  # pragma: no cover - exercised via CI venv
            raise ConfigError(f"PyJWT is required for authentication: {error}")
        self._key_id = key_id
        self._issuer_id = issuer_id
        self._private_key = private_key
        self._clock = clock
        self._redactor = redactor
        self._cached: Optional[str] = None
        self._cached_expiry = 0.0

    def token(self) -> str:
        now = self._clock.monotonic()
        if self._cached and now < self._cached_expiry - TOKEN_REFRESH_MARGIN_SECONDS:
            return self._cached
        import jwt

        issued = int(self._clock.utcnow().timestamp())
        payload = {
            "iss": self._issuer_id,
            "iat": issued,
            "exp": issued + JWT_LIFETIME_SECONDS,
            "aud": JWT_AUDIENCE,
        }
        try:
            token = jwt.encode(payload, self._private_key, algorithm="ES256",
                               headers={"kid": self._key_id, "typ": "JWT"})
        except Exception as error:  # noqa: BLE001 - surface as config failure
            raise ConfigError(f"could not sign App Store Connect token: {error}")
        if isinstance(token, bytes):  # PyJWT < 2 returned bytes
            token = token.decode("ascii")
        self._cached = token
        self._cached_expiry = now + JWT_LIFETIME_SECONDS
        if self._redactor is not None:
            self._redactor.add(token)
        return token


# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #
@dataclass
class MonitorConfig:
    role: str
    workflow_id: str
    expected_sha: str
    branch: Optional[str] = None
    ref_kind: str = "branch"  # "branch" or "tag"
    pull_request: Optional[int] = None
    alert_deadline_seconds: float = DEFAULT_ALERT_DEADLINE_SECONDS
    poll_seconds: float = DEFAULT_POLL_SECONDS
    http_timeout_seconds: float = DEFAULT_HTTP_TIMEOUT_SECONDS
    require_manual_only: bool = True
    preflight_only: bool = False

    def target(self) -> str:
        if self.pull_request is not None:
            return f"pull request #{self.pull_request}"
        return f"{self.ref_kind} {self.branch}"


def _positive_finite(label: str, value) -> float:
    """Return ``value`` as a positive, finite float, or fail closed."""
    try:
        number = float(value)
    except (TypeError, ValueError):
        raise ConfigError(f"{label} must be a number")
    if not math.isfinite(number) or number <= 0:
        raise ConfigError(f"{label} must be a positive, finite number")
    return number


def build_config(args, env: dict) -> MonitorConfig:
    """Validate non-secret config. Missing or malformed values fail closed.

    Values are validated as given: a workflow id or commit SHA that carries
    surrounding whitespace is rejected, never silently stripped and repaired.
    """

    workflow_id = args.workflow_id or env.get("XCODE_CLOUD_WORKFLOW_ID") or ""
    if not workflow_id:
        raise ConfigError("no Cloud workflow id: pass --workflow-id or set the repo variable")
    if "://" in workflow_id or "/" in workflow_id or any(c.isspace() for c in workflow_id):
        raise ConfigError("workflow id must be a bare identifier, never a URL or padded with whitespace")
    if not WORKFLOW_ID_RE.match(workflow_id):
        raise ConfigError(f"workflow id {workflow_id!r} is not a valid identifier")

    expected_sha = args.expected_sha or ""
    # A full commit id is required. An abbreviated SHA would let Cloud build a
    # different commit than the one the caller intended and only mismatch later.
    if not re.fullmatch(r"(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})", expected_sha):
        raise ConfigError("expected SHA must be a full 40- or 64-character hexadecimal commit id")

    if args.pull_request is not None and args.branch:
        raise ConfigError("choose either --branch or --pull-request, not both")
    if args.pull_request is None and not (args.branch or ""):
        raise ConfigError("a branch/tag or a pull request number is required")

    ref_kind = args.ref_kind
    if ref_kind not in ("branch", "tag"):
        raise ConfigError("--ref-kind must be 'branch' or 'tag'")

    deadline = _positive_finite("alert deadline", args.alert_deadline)
    poll = _positive_finite("poll interval", args.poll)
    timeout = _positive_finite("http timeout", args.http_timeout)

    return MonitorConfig(
        role=args.role,
        workflow_id=workflow_id,
        expected_sha=expected_sha,
        branch=(args.branch or None),
        ref_kind=ref_kind,
        pull_request=args.pull_request,
        alert_deadline_seconds=deadline,
        poll_seconds=poll,
        http_timeout_seconds=timeout,
        require_manual_only=not args.allow_automatic_start_conditions,
        preflight_only=args.command == "preflight",
    )


def load_credentials(env: dict, redactor: Redactor) -> tuple[str, str, str]:
    """Return (key_id, issuer_id, private_key) or fail closed before any start."""
    key_id = (env.get("APP_STORE_CONNECT_KEY_ID") or "").strip()
    issuer_id = (env.get("APP_STORE_CONNECT_ISSUER_ID") or "").strip()
    private_key = env.get("APP_STORE_CONNECT_PRIVATE_KEY") or ""
    missing = [name for name, value in (
        ("APP_STORE_CONNECT_KEY_ID", key_id),
        ("APP_STORE_CONNECT_ISSUER_ID", issuer_id),
        ("APP_STORE_CONNECT_PRIVATE_KEY", private_key),
    ) if not value]
    if missing:
        raise ConfigError("missing required secret(s): " + ", ".join(missing))
    redactor.add(private_key)
    return key_id, issuer_id, private_key


# --------------------------------------------------------------------------- #
# Step summary / annotations
# --------------------------------------------------------------------------- #
class StepSummary:
    """Appends Markdown to GITHUB_STEP_SUMMARY when present, else logs."""

    def __init__(self, path: Optional[str], log: Callable[[str], None]):
        self._path = path
        self._log = log

    def write(self, markdown: str) -> None:
        if not self._path:
            self._log(markdown)
            return
        try:
            with open(self._path, "a", encoding="utf-8") as handle:
                handle.write(markdown.rstrip("\n") + "\n")
        except OSError as error:
            self._log(f"could not write step summary: {error}")


# --------------------------------------------------------------------------- #
# GitHub alerting
# --------------------------------------------------------------------------- #
class GitHubAlerter:
    """Posts at most one comment per run to the PR that triggered the monitor.

    Uses the authenticated REST API with GITHUB_TOKEN. Never logs the token.
    Failures here are reported but do not change the monitor's own exit code --
    the Actions job still fails and still carries an annotation.
    """

    def __init__(self, http: HttpClient, token: str, repo: str,
                 pr_number: Optional[int], log: Callable[[str], None],
                 *, redactor: Redactor, timeout: float = DEFAULT_HTTP_TIMEOUT_SECONDS):
        self._http = http
        self._token = token
        self._repo = repo
        self._pr = pr_number
        self._log = log
        self._redactor = redactor
        self._timeout = timeout

    def available(self) -> bool:
        return bool(self._token and self._repo and self._pr)

    def _headers(self) -> dict:
        return {
            "Authorization": f"Bearer {self._token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "nitrate-cloud-monitor",
            "Content-Type": "application/json",
        }

    def comment_once(self, marker: str, body: str) -> bool:
        """Post ``body`` unless a comment carrying ``marker`` already exists."""
        if not self.available():
            self._log("alert comment skipped: no GITHUB_TOKEN/repository/pull request available")
            return False
        comments_url = f"{GITHUB_API_BASE}/repos/{self._repo}/issues/{self._pr}/comments"
        try:
            validate_api_url(comments_url, GITHUB_API_HOST)
        except ShapeError as error:
            self._log(f"alert comment skipped: {error}")
            return False
        try:
            existing = self._http.request("GET", comments_url + "?per_page=100",
                                          headers=self._headers(), timeout=self._timeout)
        except NetworkError as error:
            self._log(f"alert comment skipped: {self._redactor(str(error))}")
            return False
        if existing.status == 200:
            try:
                comments = existing.json()
            except ShapeError:
                comments = None
            if isinstance(comments, list) and any(
                isinstance(c, dict) and marker in (c.get("body") or "") for c in comments
            ):
                self._log("alert comment already present; not duplicating")
                return False
        else:
            self._log(f"could not list existing comments (status {existing.status}); "
                      "posting without duplicate check")

        payload = json.dumps({"body": f"{marker}\n\n{body}"}).encode("utf-8")
        try:
            response = self._http.request("POST", comments_url, headers=self._headers(),
                                          body=payload, timeout=self._timeout)
        except NetworkError as error:
            self._log(f"alert comment failed: {self._redactor(str(error))}")
            return False
        if response.status in (200, 201):
            self._log("alert comment posted")
            return True
        self._log(f"alert comment rejected (status {response.status}); "
                  "the Actions job still fails and notifies")
        return False


# --------------------------------------------------------------------------- #
# The monitor
# --------------------------------------------------------------------------- #
@dataclass
class RunRecord:
    run_id: str
    number: Optional[int] = None


class CloudMonitor:
    def __init__(self, *, config: MonitorConfig, http: HttpClient, clock: Clock,
                 token_provider: TokenProvider, redactor: Redactor,
                 log: Callable[[str], None], summary: StepSummary,
                 alerter: Optional[GitHubAlerter] = None):
        self.config = config
        self.http = http
        self.clock = clock
        self.token_provider = token_provider
        self.redactor = redactor
        self.log = lambda message: log(self.redactor(message))
        self.summary = summary
        self.alerter = alerter
        self.run: Optional[RunRecord] = None
        self._monitor_start = 0.0
        # Set to True the instant before the POST is issued. Once it is set, the
        # Cloud build may exist even if the response is lost, so every later
        # failure must tell the operator to check/cancel manually.
        self.launch_attempted = False
        # Set to True the moment a run is seen (or reported) COMPLETE. A finished
        # run can never still be running, so a later failure must not claim it may
        # be, and a completed run must never be told to cancel itself.
        self.completed_confirmed = False

    # -- HTTP helpers ------------------------------------------------------ #
    def _headers(self) -> dict:
        return {
            "Authorization": f"Bearer {self.token_provider.token()}",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": "nitrate-cloud-monitor",
        }

    def _remaining_budget(self) -> float:
        """Seconds left before the alert deadline (never negative)."""
        return self.config.alert_deadline_seconds - (self.clock.monotonic() - self._monitor_start)

    def _call(self, method: str, url: str, *, body: Optional[bytes] = None,
              ok: tuple = (200,)) -> HttpResponse:
        # Never send the Apple JWT anywhere but the exact API host, and never
        # spend more of the deadline budget than remains.
        validate_api_url(url, APPLE_API_HOST)
        remaining = self._remaining_budget()
        if remaining <= 0:
            raise DeadlineExceeded(
                f"the alert deadline expired before {method} {url}; refusing to continue")
        timeout = min(self.config.http_timeout_seconds, remaining)
        try:
            response = self.http.request(method, url, headers=self._headers(),
                                         body=body, timeout=timeout)
        except NetworkError:
            raise
        if response.status not in ok:
            detail = self._error_detail(response)
            raise ApiError(f"{method} {url} returned {response.status}{detail}",
                           status=response.status)
        return response

    def _error_detail(self, response: HttpResponse) -> str:
        try:
            payload = response.json()
        except ShapeError:
            return ""
        if isinstance(payload, dict) and isinstance(payload.get("errors"), list):
            parts = []
            for item in payload["errors"]:
                if isinstance(item, dict):
                    parts.append(str(item.get("detail") or item.get("title") or item.get("code")))
            if parts:
                return ": " + "; ".join(parts)
        return ""

    def _get_json(self, url: str) -> dict:
        payload = self._call("GET", url).json()
        if not isinstance(payload, dict):
            raise ShapeError(f"expected a JSON object from {url}")
        return payload

    def _paginate(self, url: str) -> list:
        """Follow ``links.next`` until exhausted, bounded by MAX_PAGES."""
        items: list = []
        page = 0
        while url:
            page += 1
            if page > MAX_PAGES:
                raise ShapeError(f"pagination exceeded {MAX_PAGES} pages")
            payload = self._get_json(url)
            data = payload.get("data")
            if not isinstance(data, list):
                raise ShapeError(f"expected a data array from {url}")
            items.extend(data)
            links = payload.get("links")
            if links is None:
                break
            if not isinstance(links, dict):
                raise ShapeError(f"expected a links object from {url}")
            nxt = links.get("next")
            if nxt is None:
                break
            if not isinstance(nxt, str):
                raise ShapeError(f"pagination 'next' link was not a string from {url}")
            url = nxt
        return items

    # -- Preflight --------------------------------------------------------- #
    def _get_workflow(self) -> dict:
        # Apple omits relationship linkage unless explicitly included.
        payload = self._get_json(
            f"{API_BASE}/v1/ciWorkflows/{self.config.workflow_id}?include=product,repository")
        data = payload.get("data")
        if not isinstance(data, dict):
            raise ShapeError("workflow response did not contain a data object")
        if data.get("type") != "ciWorkflows":
            raise ShapeError("workflow response was not a ciWorkflows resource")
        return data

    def _repository_id(self, workflow: dict) -> str:
        relationships = workflow.get("relationships")
        if isinstance(relationships, dict):
            repo = relationships.get("repository")
            if isinstance(repo, dict):
                data = repo.get("data")
                if isinstance(data, dict) and isinstance(data.get("id"), str):
                    return data["id"]
        payload = self._get_json(f"{API_BASE}/v1/ciWorkflows/{self.config.workflow_id}/repository")
        data = payload.get("data")
        if isinstance(data, dict) and isinstance(data.get("id"), str):
            return data["id"]
        raise ShapeError("could not resolve the workflow's SCM repository id")

    def _product_id(self, workflow: dict) -> str:
        """The Xcode Cloud product this workflow belongs to.

        Concurrency is per product, not per workflow: a release build and a test
        build share the same compute, so the product id is required to check for
        an active run anywhere in the product.
        """
        relationships = workflow.get("relationships")
        if isinstance(relationships, dict):
            product = relationships.get("product")
            if isinstance(product, dict):
                data = product.get("data")
                if isinstance(data, dict) and isinstance(data.get("id"), str):
                    return data["id"]
        raise ShapeError("could not resolve the workflow's Xcode Cloud product id")

    @staticmethod
    def _automatic_condition_present(value) -> bool:
        """True when an automatic start condition is set to anything but empty.

        This is deliberately strict: any non-empty object counts as an active
        automatic trigger (so an unrecognised field cannot slip through), and a
        non-object, non-null value is an unexpected shape and fails closed.
        """
        if value is None:
            return False
        if not isinstance(value, dict):
            raise ShapeError("an automatic start condition had an unexpected, non-object shape")
        return bool(value)

    def check_start_conditions(self, workflow: dict) -> list:
        attributes = workflow.get("attributes")
        if not isinstance(attributes, dict):
            raise ShapeError("workflow response had no attributes object")
        enabled = [name for name in AUTOMATIC_START_CONDITIONS
                   if self._automatic_condition_present(attributes.get(name))]
        return enabled

    def check_role_actions(self, workflow: dict) -> None:
        """Require the workflow's actions to match the role's fixed contract.

        The role must not be a label: the ``test`` role needs a single TEST
        action (RenderCLI scheme, MACOS platform, exactly one destination) and
        the ``release`` role needs a single ARCHIVE action (Nitrate scheme). Any
        other action, or any extra action, would spend compute the role did not
        ask for and is refused before a build starts.
        """
        contract = ROLE_ACTION_CONTRACT.get(self.config.role)
        if contract is None:
            raise ConfigError(f"unknown role {self.config.role!r}")
        attributes = workflow.get("attributes")
        if not isinstance(attributes, dict):
            raise ShapeError("workflow response had no attributes object")
        actions = attributes.get("actions")
        if not isinstance(actions, list) or not actions:
            raise PreflightError(
                f"Cloud workflow {self.config.workflow_id} declares no actions; "
                f"the {self.config.role} role requires exactly one")
        for action in actions:
            if not isinstance(action, dict):
                raise ShapeError("workflow action was not an object")
            action_type = action.get("actionType")
            if action_type not in CI_ACTION_TYPES:
                raise ShapeError(f"workflow action had an unknown actionType {action_type!r}")
            platform = action.get("platform")
            if platform is not None and platform not in CI_ACTION_PLATFORMS:
                raise ShapeError(f"workflow action had an unknown platform {platform!r}")
        wanted = contract["actionType"]
        matching = [a for a in actions if a.get("actionType") == wanted]
        if len(actions) != 1 or len(matching) != 1:
            raise PreflightError(
                f"the {self.config.role} workflow must declare exactly one {wanted} action "
                "and no other actions (extra actions spend Cloud compute)")
        action = matching[0]
        if action.get("scheme") != contract["scheme"]:
            raise PreflightError(
                f"the {wanted} action must use the {contract['scheme']} scheme, "
                f"found {action.get('scheme')!r}")
        if contract["platform"] is not None and action.get("platform") != contract["platform"]:
            raise PreflightError(
                f"the {wanted} action must target the {contract['platform']} platform, "
                f"found {action.get('platform')!r}")
        if contract["require_single_destination"]:
            configuration = action.get("testConfiguration")
            if not isinstance(configuration, dict):
                raise PreflightError("the TEST action has no test configuration")
            destinations = configuration.get("testDestinations")
            if not isinstance(destinations, list) or len(destinations) != 1:
                raise PreflightError(
                    "the TEST action must declare exactly one test destination "
                    "(multiple destinations multiply Cloud compute)")

    def resolve_ref(self, repository_id: str) -> str:
        """Resolve the exact branch/tag SCM git reference id."""
        want_branch = self.config.ref_kind == "branch"
        wanted = self.config.branch
        canonical = f"refs/{'heads' if want_branch else 'tags'}/{wanted}"
        url = f"{API_BASE}/v1/scmRepositories/{repository_id}/gitReferences?limit=200"
        matches = []
        for item in self._paginate(url):
            if not isinstance(item, dict):
                raise ShapeError("git reference list contained a non-object entry")
            attributes = item.get("attributes")
            if not isinstance(attributes, dict):
                continue
            if attributes.get("isDeleted") is True:
                continue
            kind = attributes.get("kind")
            if kind not in ("BRANCH", "TAG"):
                continue
            if (kind == "BRANCH") != want_branch:
                continue
            names = {attributes.get("name"), attributes.get("canonicalName")}
            if wanted in names or canonical in names:
                ref_id = item.get("id")
                if not isinstance(ref_id, str):
                    raise ShapeError("git reference was missing an id")
                matches.append(ref_id)
        if not matches:
            raise PreflightError(f"no {self.config.ref_kind} named {wanted!r} in the repository")
        if len(set(matches)) > 1:
            raise PreflightError(f"ambiguous {self.config.ref_kind} {wanted!r}: "
                                 f"{len(set(matches))} references matched")
        return matches[0]

    def resolve_pull_request(self, repository_id: str) -> str:
        """Resolve a same-repo (never fork) pull request id."""
        wanted = self.config.pull_request
        url = f"{API_BASE}/v1/scmRepositories/{repository_id}/pullRequests?limit=200"
        for item in self._paginate(url):
            if not isinstance(item, dict):
                raise ShapeError("pull request list contained a non-object entry")
            attributes = item.get("attributes")
            if not isinstance(attributes, dict):
                continue
            if attributes.get("number") != wanted:
                continue
            if attributes.get("isCrossRepository") is True:
                raise PreflightError(
                    f"pull request #{wanted} is a cross-repository (fork) PR; "
                    "refusing to start it because secrets must not reach forks")
            pr_id = item.get("id")
            if not isinstance(pr_id, str):
                raise ShapeError("pull request was missing an id")
            return pr_id
        raise PreflightError(f"pull request #{wanted} was not found in the repository")

    def active_runs(self, product_id: str) -> list:
        """Every PENDING/RUNNING run for the whole product, across all pages.

        Concurrency is enforced by the product, not the workflow: a test run and
        a release run contend for the same compute. Checking only this workflow
        would let a release build start while a timed-out test monitor's Cloud
        run is still going. A run with an unrecognised progress value is a shape
        error, never silently skipped.
        """
        url = f"{API_BASE}/v1/ciProducts/{product_id}/buildRuns?limit=200"
        active = []
        for item in self._paginate(url):
            if not isinstance(item, dict):
                raise ShapeError("build run list contained a non-object entry")
            attributes = item.get("attributes")
            if not isinstance(attributes, dict):
                raise ShapeError("build run had no attributes object")
            progress = attributes.get("executionProgress")
            if progress not in CI_EXECUTION_PROGRESS:
                raise ShapeError(
                    f"unknown executionProgress {progress!r} in a product build run")
            if progress in ("PENDING", "RUNNING"):
                run_id = item.get("id")
                if not isinstance(run_id, str):
                    raise ShapeError("an active build run was missing an id")
                active.append({
                    "id": run_id,
                    "number": attributes.get("number"),
                    "progress": progress,
                })
        return active

    # -- Start ------------------------------------------------------------- #
    def start_run(self, *, workflow_id: str, ref_id: Optional[str],
                  pull_request_id: Optional[str]) -> dict:
        relationships: dict = {
            "workflow": {"data": {"type": "ciWorkflows", "id": workflow_id}},
        }
        if pull_request_id is not None:
            relationships["pullRequest"] = {
                "data": {"type": "scmPullRequests", "id": pull_request_id}}
        else:
            relationships["sourceBranchOrTag"] = {
                "data": {"type": "scmGitReferences", "id": ref_id}}
        body = json.dumps({
            "data": {"type": "ciBuildRuns", "relationships": relationships}
        }).encode("utf-8")
        # Mark the attempt BEFORE the request leaves: once the POST is in flight
        # the build may exist even if the response never arrives, so the run must
        # never be retried and every later failure must warn about a possibly
        # running Cloud build.
        self.launch_attempted = True
        try:
            response = self._call("POST", f"{API_BASE}/v1/ciBuildRuns", body=body, ok=(201,))
        except (ApiError, NetworkError) as error:
            raise StartError(f"could not start the Cloud build: {error}")
        try:
            payload = response.json()
        except ShapeError as error:
            raise StartError(f"the start response could not be read: {error}")
        data = payload.get("data") if isinstance(payload, dict) else None
        if not isinstance(data, dict) or not isinstance(data.get("id"), str):
            raise StartError("the start response did not identify the created build run")
        return data

    # -- Polling ----------------------------------------------------------- #
    def get_run(self, run_id: str) -> dict:
        payload = self._get_json(f"{API_BASE}/v1/ciBuildRuns/{run_id}")
        data = payload.get("data")
        if not isinstance(data, dict):
            raise ShapeError("build run response did not contain a data object")
        return data

    def verify_test_results(self, run_id: str) -> dict:
        """Confirm a SUCCEEDED test run actually ran tests and they passed.

        A green completion is not trusted on its own: the run must expose a TEST
        action, that action must report at least one test result across complete
        pagination, and no result may be FAILURE/MIXED. SKIPPED results are
        counted and reported, never silently treated as "no tests".
        """
        actions = self._paginate(f"{API_BASE}/v1/ciBuildRuns/{run_id}/actions?limit=200")
        test_action_ids = []
        for action in actions:
            if not isinstance(action, dict):
                raise ShapeError("build action list contained a non-object entry")
            attributes = action.get("attributes")
            if not isinstance(attributes, dict):
                raise ShapeError("build action had no attributes object")
            if attributes.get("actionType") == "TEST":
                action_id = action.get("id")
                if not isinstance(action_id, str):
                    raise ShapeError("a TEST action was missing an id")
                test_action_ids.append(action_id)
        if not test_action_ids:
            raise TestResultError(
                f"run {run_id} SUCCEEDED but reported no TEST action; refusing to accept it")

        results: list = []
        for action_id in test_action_ids:
            results.extend(self._paginate(
                f"{API_BASE}/v1/ciBuildActions/{action_id}/testResults?limit=200"))
        if not results:
            raise TestResultError(
                f"run {run_id} SUCCEEDED but the TEST action reported zero test results; "
                "refusing to accept it")

        failures = 0
        skipped = 0
        for result in results:
            if not isinstance(result, dict):
                raise ShapeError("test result list contained a non-object entry")
            attributes = result.get("attributes")
            if not isinstance(attributes, dict):
                raise ShapeError("test result had no attributes object")
            status = attributes.get("status")
            if status not in CI_TEST_STATUSES:
                raise ShapeError(f"unknown CiTestStatus {status!r} in a test result")
            failing = status in CI_TEST_FAILING_STATUSES
            executed = status != "SKIPPED"
            # The official spec also nests a per-destination status array; a
            # green overall status must not hide a FAILURE/MIXED leaf, and a
            # result whose every destination was SKIPPED did not execute.
            destinations = attributes.get("destinationTestResults")
            if destinations is not None:
                if not isinstance(destinations, list):
                    raise ShapeError("destinationTestResults was not an array")
                for destination in destinations:
                    if not isinstance(destination, dict):
                        raise ShapeError("a destinationTestResult was not an object")
                    dest_status = destination.get("status")
                    if dest_status not in CI_TEST_STATUSES:
                        raise ShapeError(
                            f"unknown CiTestStatus {dest_status!r} in a destination test result")
                    if dest_status in CI_TEST_FAILING_STATUSES:
                        failing = True
                if destinations and all(d.get("status") == "SKIPPED" for d in destinations):
                    executed = False
            if failing:
                failures += 1
            elif not executed:
                skipped += 1
        if failures:
            raise TestResultError(
                f"run {run_id} SUCCEEDED but {failures} test result(s) were FAILURE/MIXED; "
                "refusing to accept it")
        if skipped == len(results):
            raise TestResultError(
                f"run {run_id} SUCCEEDED but every test result was SKIPPED; "
                "zero executed tests cannot establish a passing test run")
        return {"total": len(results), "skipped": skipped}

    @staticmethod
    def source_commit_sha(run: dict) -> Optional[str]:
        attributes = run.get("attributes")
        if not isinstance(attributes, dict):
            return None
        source = attributes.get("sourceCommit")
        if not isinstance(source, dict):
            return None
        sha = source.get("commitSha")
        if isinstance(sha, str) and sha.strip():
            return sha.strip()
        return None

    @staticmethod
    def created_date(run: dict) -> Optional[datetime]:
        attributes = run.get("attributes")
        if not isinstance(attributes, dict):
            return None
        raw = attributes.get("createdDate")
        if not isinstance(raw, str):
            return None
        try:
            return datetime.fromisoformat(raw.replace("Z", "+00:00"))
        except ValueError:
            return None

    def _elapsed(self, run: Optional[dict]) -> float:
        elapsed = self.clock.monotonic() - self._monitor_start
        created = self.created_date(run) if run else None
        if created is not None:
            created_elapsed = (self.clock.utcnow() - created).total_seconds()
            elapsed = max(elapsed, created_elapsed)
        return elapsed

    # -- Alerting ---------------------------------------------------------- #
    def _record_run(self, run: dict) -> RunRecord:
        run_id = run.get("id")
        if not isinstance(run_id, str):
            raise ShapeError("build run had no id")
        attributes = run.get("attributes") if isinstance(run.get("attributes"), dict) else {}
        number = attributes.get("number")
        return RunRecord(run_id=run_id, number=number if isinstance(number, int) else None)

    def _alert(self, *, marker: str, headline: str, body: str, annotation: str) -> None:
        self.log(headline)
        print(f"::error title=Xcode Cloud monitor::{annotation}")
        self.summary.write(f"## {headline}\n\n{body}\n")
        if self.alerter is not None:
            self.alerter.comment_once(marker, body)

    def _deadline_failure(self, run: RunRecord, elapsed: float) -> int:
        headline = "CLOUD MAY STILL BE RUNNING — MANUAL CANCEL REQUIRED"
        number = run.number if run.number is not None else "unknown"
        body = (
            f"The Xcode Cloud alert deadline "
            f"({self.config.alert_deadline_seconds:.0f}s) was exceeded after "
            f"{elapsed:.0f}s.\n\n"
            f"- Run id: `{run.run_id}`\n"
            f"- Run number: `{number}`\n"
            f"- Target: {self.config.target()}\n\n"
            "The App Store Connect API exposes **no cancel endpoint** "
            "(0 of 1303 operations), so this monitor cannot stop the run. "
            "Cancel it manually in App Store Connect → Xcode Cloud → Builds, "
            "or in Xcode. This job is failing so Actions notifies you."
        )
        self._alert(marker=f"<!-- cloud-monitor-alert:deadline:{run.run_id} -->",
                    headline=headline, body=body,
                    annotation=f"Xcode Cloud run {run.run_id} exceeded the "
                               f"{self.config.alert_deadline_seconds:.0f}s alert deadline; "
                               "manual cancellation required")
        return EXIT_DEADLINE

    # -- Orchestration ----------------------------------------------------- #
    def run_monitor(self) -> int:
        self._monitor_start = self.clock.monotonic()
        config = self.config

        self.log(f"Cloud monitor: role={config.role} workflow={config.workflow_id} "
                 f"target={config.target()} expected_sha={config.expected_sha} "
                 f"deadline={config.alert_deadline_seconds:.0f}s")

        # 1. Workflow + native start conditions + role/action contract.
        workflow = self._get_workflow()
        attributes = workflow.get("attributes") or {}
        if attributes.get("isEnabled") is not True:
            raise PreflightError(f"Cloud workflow {config.workflow_id} is not enabled")
        if config.require_manual_only:
            enabled = self.check_start_conditions(workflow)
            if enabled:
                raise PreflightError(
                    "Cloud workflow has native automatic start conditions "
                    f"({', '.join(enabled)}); every launch must be monitor-driven, "
                    "so disable them in App Store Connect before starting")
        self.check_role_actions(workflow)
        repository_id = self._repository_id(workflow)
        product_id = self._product_id(workflow)

        # 2. Resolve the exact ref or same-repo pull request.
        ref_id: Optional[str] = None
        pull_request_id: Optional[str] = None
        if config.pull_request is not None:
            pull_request_id = self.resolve_pull_request(repository_id)
            self.log(f"resolved pull request #{config.pull_request} -> {pull_request_id}")
        else:
            ref_id = self.resolve_ref(repository_id)
            self.log(f"resolved {config.ref_kind} {config.branch} -> {ref_id}")

        # 3. Preflight active runs across the WHOLE product and all pages.
        active = self.active_runs(product_id)
        if active:
            summary = ", ".join(f"#{a['number']}({a['progress']})" for a in active)
            raise ActiveBuildError(
                f"{len(active)} active run(s) already exist for this product ({summary}); "
                "refusing to start a second build and double the compute")

        if config.preflight_only:
            self.log("preflight passed: credentials valid, workflow enabled and "
                     "manual-only, role actions match, ref resolved, no active runs")
            self.summary.write("## Cloud monitor preflight\n\n"
                               "Credentials valid, workflow enabled and manual-only, role "
                               "actions match, ref resolved, no active product runs. "
                               "No build was started.\n")
            return EXIT_OK

        # 4. The deadline also governs preflight: never launch if the budget the
        # preflight calls consumed has already run out.
        if self._remaining_budget() <= 0:
            raise DeadlineExceeded(
                "the alert deadline expired during preflight; refusing to start a build")

        # 5. Start exactly once. No retries: a retry would create a second build.
        started = self.start_run(workflow_id=config.workflow_id, ref_id=ref_id,
                                 pull_request_id=pull_request_id)
        run = self._record_run(started)
        self.run = run
        if (started.get("attributes") or {}).get("executionProgress") == "COMPLETE":
            # The start response already reports a finished run.
            self.completed_confirmed = True
        number = run.number if run.number is not None else "unknown"
        self.log(f"started Cloud run {run.run_id} (#{number})")

        # 6. Verify the reported source commit before accepting any pass.
        reported = self.source_commit_sha(started)
        if reported is not None:
            self._verify_sha(reported, run)
        else:
            self.log("sourceCommit not reported yet; will verify during polling")

        # 7. Poll until completion or the alert deadline.
        return self._poll(run)

    def _verify_sha(self, reported: str, run: RunRecord) -> None:
        if reported.lower() == self.config.expected_sha.lower():
            return
        number = run.number if run.number is not None else "unknown"
        if self.completed_confirmed:
            # The run already finished, so there is nothing left to cancel; the
            # dedicated mismatch alert must not tell the operator to cancel it.
            headline = "CLOUD SOURCE COMMIT MISMATCH — RUN COMPLETED"
            body = (
                f"Cloud reported source commit `{reported}` but "
                f"`{self.config.expected_sha}` was expected.\n\n"
                f"- Run id: `{run.run_id}`\n"
                f"- Run number: `{number}`\n\n"
                "The run has already completed, so no build is still running and "
                "nothing needs to be cancelled; the result is rejected because it "
                "built the wrong commit. This job is failing so Actions notifies you."
            )
            annotation = (f"Cloud run {run.run_id} completed at {reported}, "
                          f"expected {self.config.expected_sha}")
        else:
            headline = "CLOUD SOURCE COMMIT MISMATCH — MANUAL CANCEL REQUIRED"
            body = (
                f"Cloud reported source commit `{reported}` but "
                f"`{self.config.expected_sha}` was expected.\n\n"
                f"- Run id: `{run.run_id}`\n"
                f"- Run number: `{number}`\n\n"
                "The API cannot cancel a run, so cancel it manually in App Store "
                "Connect → Xcode Cloud → Builds. This job is failing so Actions notifies you."
            )
            annotation = (f"Cloud run {run.run_id} built {reported}, "
                          f"expected {self.config.expected_sha}; manual cancellation required")
        self._alert(marker=f"<!-- cloud-monitor-alert:sha:{run.run_id} -->",
                    headline=headline, body=body, annotation=annotation)
        raise SourceCommitMismatch(f"source commit mismatch: {reported} != {self.config.expected_sha}")

    def _poll(self, run: RunRecord) -> int:
        deadline = self.config.alert_deadline_seconds
        verified_sha = False
        current: Optional[dict] = None
        while True:
            # Check the deadline before the next request so a slow API can never
            # push the monitor past its budget on a network call.
            elapsed = self._elapsed(current)
            if elapsed >= deadline:
                return self._deadline_failure(run, elapsed)

            current = self.get_run(run.run_id)

            attributes = current.get("attributes") or {}
            progress = attributes.get("executionProgress")
            completion = attributes.get("completionStatus")
            if progress == "COMPLETE":
                # Record definite completion BEFORE the SHA check: a finished run
                # can never still be running, so a mismatch here must not request a
                # cancel and a later failure must not claim a possible launch.
                self.completed_confirmed = True

            reported = self.source_commit_sha(current)
            if reported is not None and not verified_sha:
                self._verify_sha(reported, run)
                verified_sha = True
                self.log(f"verified source commit {reported}")

            if progress == "COMPLETE":
                return self._finish(run, attributes, completion, verified_sha, reported)
            if progress not in ("PENDING", "RUNNING"):
                raise ShapeError(f"unexpected executionProgress {progress!r} for run {run.run_id}")

            self.log(f"run {run.run_id} {progress} "
                     f"({elapsed:.0f}s / {deadline:.0f}s)")
            self.clock.sleep(min(self.config.poll_seconds, max(0.0, deadline - elapsed)))

    def _finish(self, run: RunRecord, attributes: dict, completion,
                verified_sha: bool, reported: Optional[str]) -> int:
        number = run.number if run.number is not None else "unknown"
        if not verified_sha or reported is None:
            raise ShapeError(
                f"run {run.run_id} completed without a verifiable sourceCommit; "
                "refusing to accept the result")
        if completion == "SUCCEEDED":
            detail = ""
            if self.config.role == "test":
                # A green completion is only accepted once the TEST action has
                # actually reported non-empty, non-failing test results.
                counts = self.verify_test_results(run.run_id)
                detail = f" Verified {counts['total']} test result(s)"
                if counts["skipped"]:
                    detail += f" ({counts['skipped']} skipped)"
                detail += "."
            self.log(f"run {run.run_id} (#{number}) SUCCEEDED at {reported}")
            self.summary.write(
                f"## Cloud monitor passed\n\nRun `{run.run_id}` (#{number}) "
                f"SUCCEEDED for {self.config.target()} at `{reported}`.{detail}\n")
            return EXIT_OK
        headline = f"Cloud run #{number} finished with {completion}"
        body = (f"Run `{run.run_id}` (#{number}) completed with "
                f"`{completion}` for {self.config.target()} at `{reported}`.\n")
        self.log(headline)
        self.summary.write(f"## {headline}\n\n{body}")
        return EXIT_BUILD_FAILED

    def interrupt_notice(self) -> None:
        run = self.run
        if run is None:
            if self.launch_attempted:
                message = (
                    "Interrupted after the start request was sent; the build run id "
                    "is unknown and the Cloud build MAY STILL BE RUNNING. Check "
                    "Xcode Cloud for a build this workflow started and cancel it "
                    "manually if one is running.")
                self.log(message)
                print(f"::warning title=Xcode Cloud monitor::{message}")
                self.summary.write(f"## Interrupted\n\n{message}\n")
                return
            self.log("interrupted before a build started; nothing was launched")
            return
        number = run.number if run.number is not None else "unknown"
        if self.completed_confirmed:
            # The run already reached COMPLETE, so nothing is still running.
            message = (f"Interrupted. Cloud run {run.run_id} (#{number}) had already "
                       "completed; nothing is still running and no cancellation is needed.")
            self.log(message)
            self.summary.write(f"## Interrupted\n\n{message}\n")
            return
        message = (
            f"Interrupted. Cloud run {run.run_id} (#{number}) MAY STILL BE RUNNING. "
            "The API has no cancel endpoint — cancel it manually in App Store "
            "Connect → Xcode Cloud → Builds or in Xcode.")
        self.log(message)
        print(f"::warning title=Xcode Cloud monitor::{message}")
        self.summary.write(f"## Interrupted\n\n{message}\n")

    def launch_uncertain_notice(self, error: Exception) -> None:
        """Warn that a launch was attempted but its outcome is unknown.

        Reached whenever the POST was issued (``launch_attempted``) and anything
        afterwards failed: a lost connection, an unreadable response, or a
        response without a run id. The Cloud build may exist regardless, so the
        operator is told to check the workflow and cancel manually. The run id is
        reported when known, otherwise the workflow id is given instead.
        """
        run = self.run
        if run is not None:
            target = f"Run id: `{run.run_id}`"
        else:
            target = (f"Run id: unknown — inspect workflow `{self.config.workflow_id}` "
                      "in App Store Connect → Xcode Cloud → Builds")
        headline = "CLOUD LAUNCH OUTCOME UNKNOWN — A BUILD MAY BE RUNNING"
        body = (
            f"The start request was sent but its outcome could not be confirmed: "
            f"{error}\n\n"
            f"- Workflow id: `{self.config.workflow_id}`\n"
            f"- {target}\n"
            f"- Target: {self.config.target()}\n\n"
            "The App Store Connect API exposes **no cancel endpoint**, so this "
            "monitor cannot stop a run. Check Xcode Cloud for a build that this "
            "workflow started and cancel it manually if one is running. This job "
            "is failing so Actions notifies you."
        )
        marker_id = run.run_id if run is not None else self.config.workflow_id
        self._alert(marker=f"<!-- cloud-monitor-alert:launch-uncertain:{marker_id} -->",
                    headline=headline, body=body,
                    annotation=f"Xcode Cloud launch for workflow "
                               f"{self.config.workflow_id} may have started a build; "
                               "manual check/cancel may be required")


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def _install_signal_handlers() -> None:
    def handler(signum, _frame):
        raise Interrupted(f"received signal {signum}")

    for name in ("SIGINT", "SIGTERM"):
        signum = getattr(signal, name, None)
        if signum is None:
            continue
        try:
            signal.signal(signum, handler)
        except (ValueError, OSError):  # not on the main thread
            pass


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("start", "preflight"),
                        help="'start' launches and monitors; 'preflight' validates only")
    parser.add_argument("--role", default="test", choices=("test", "release"),
                        help="which Cloud workflow this run represents")
    parser.add_argument("--workflow-id", default=None,
                        help="Cloud workflow id (non-secret; defaults to XCODE_CLOUD_WORKFLOW_ID)")
    parser.add_argument("--branch", default="", help="branch name to build")
    parser.add_argument("--ref-kind", default="branch", choices=("branch", "tag"))
    parser.add_argument("--pull-request", type=int, default=None,
                        help="same-repo pull request number to build")
    parser.add_argument("--expected-sha", default="", help="exact commit SHA Cloud must build")
    parser.add_argument("--alert-deadline", type=float, default=DEFAULT_ALERT_DEADLINE_SECONDS,
                        help="alert deadline in seconds (default 600)")
    parser.add_argument("--poll", type=float, default=DEFAULT_POLL_SECONDS,
                        help="poll interval in seconds")
    parser.add_argument("--http-timeout", type=float, default=DEFAULT_HTTP_TIMEOUT_SECONDS,
                        help="per-request HTTP timeout in seconds")
    parser.add_argument("--allow-automatic-start-conditions", action="store_true",
                        help="do not refuse when the workflow has native automatic triggers")
    parser.add_argument("--alert-pr", type=int, default=None,
                        help="pull request number to comment on for alerts")
    return parser


def _pr_number_from_env(env: dict, override: Optional[int]) -> Optional[int]:
    if override is not None:
        return override
    path = env.get("GITHUB_EVENT_PATH")
    if path and os.path.isfile(path):
        try:
            with open(path, encoding="utf-8") as handle:
                event = json.load(handle)
            if not isinstance(event, dict):
                return None
            pull_request = event.get("pull_request")
            number = pull_request.get("number") if isinstance(pull_request, dict) else None
            if isinstance(number, int):
                return number
        except (OSError, json.JSONDecodeError):
            return None
    return None


def main(argv: Optional[list[str]] = None, env: Optional[dict] = None,
         *, http: Optional[HttpClient] = None, clock: Optional[Clock] = None,
         token_provider: Optional[TokenProvider] = None,
         log: Optional[Callable[[str], None]] = None) -> int:
    env = dict(os.environ if env is None else env)
    args = _build_parser().parse_args(argv)

    redactor = Redactor([value for name in SECRET_ENV_NAMES
                         if (value := env.get(name))])
    log = log or (lambda message: print(message, file=sys.stderr))
    summary = StepSummary(env.get("GITHUB_STEP_SUMMARY"), log)

    monitor: Optional[CloudMonitor] = None
    try:
        config = build_config(args, env)
        key_id, issuer_id, private_key = load_credentials(env, redactor)

        clock = clock or SystemClock()
        http = http or UrllibHttpClient()
        token_provider = token_provider or JwtTokenProvider(key_id, issuer_id, private_key, clock,
                                                            redactor=redactor)

        alerter = None
        token = env.get("GITHUB_TOKEN")
        repo = env.get("GITHUB_REPOSITORY")
        pr_number = _pr_number_from_env(env, args.alert_pr)
        if token and repo:
            alerter = GitHubAlerter(http, token, repo, pr_number, log, redactor=redactor)

        monitor = CloudMonitor(config=config, http=http, clock=clock,
                               token_provider=token_provider, redactor=redactor,
                               log=log, summary=summary, alerter=alerter)
        return monitor.run_monitor()
    except Interrupted as error:
        if monitor is not None:
            monitor.interrupt_notice()
        else:
            log(f"Interrupted before start: {error}. Nothing was launched.")
        return EXIT_INTERRUPTED
    except KeyboardInterrupt:
        if monitor is not None:
            monitor.interrupt_notice()
        else:
            log("Interrupted before start. Nothing was launched.")
        return EXIT_INTERRUPTED
    except MonitorError as error:
        message = redactor(str(error))
        if isinstance(error, SourceCommitMismatch):
            # _verify_sha already emitted the dedicated source-mismatch alert.
            log(f"cloud-monitor: {message}")
        elif monitor is not None and monitor.launch_attempted and not monitor.completed_confirmed:
            # The POST was sent and the run never reached COMPLETE: the build may
            # exist and still be running, so warn to check/cancel manually.
            monitor.launch_uncertain_notice(error)
        else:
            # Nothing was launched, or the run already reached COMPLETE (nothing
            # can be running): a plain, definite failure.
            log(f"cloud-monitor: {message}")
            print(f"::error title=Xcode Cloud monitor::{message}")
            summary.write(f"## Cloud monitor failed\n\n{message}\n")
        return error.exit_code


def _run() -> int:
    _install_signal_handlers()
    try:
        return main()
    except KeyboardInterrupt:  # pragma: no cover - signal path
        print("cloud-monitor: interrupted", file=sys.stderr)
        return EXIT_INTERRUPTED


if __name__ == "__main__":
    raise SystemExit(_run())
