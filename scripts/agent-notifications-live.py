#!/usr/bin/env python3
"""Opt-in live compatibility tests for Claude and Codex terminal notifications."""

from __future__ import annotations

import argparse
import errno
import json
import os
import pty
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import tomllib
import tty
from dataclasses import dataclass
from pathlib import Path
from typing import Callable


OSC_777 = re.compile(rb"\x1b\]777;notify;[^\x07\x1b]*(?:\x07|\x1b\\)")
OSC_9 = re.compile(rb"\x1b\]9;[^\x07\x1b]*(?:\x07|\x1b\\)")
TERMINAL_QUERIES = (
    (re.compile(rb"\x1b\[6n"), b"\x1b[1;1R"),
    (re.compile(rb"\x1b\[\?6n"), b"\x1b[?1;1R"),
    (re.compile(rb"\x1b\[c"), b"\x1b[?1;2c"),
    (re.compile(rb"\x1b\[>c"), b"\x1b[>0;95;0c"),
    (re.compile(rb"\x1b\[\?u"), b"\x1b[?0u"),
)


class SetupFailure(RuntimeError):
    """A missing binary, login, network, quota, or fixture setup failure."""


class ContractFailure(RuntimeError):
    """An upstream-event or terminal-notification contract failure."""


@dataclass(frozen=True)
class Scenario:
    name: str
    prompt: str
    event: str
    blocked: bool = False
    subagent: bool = False
    marker: str | None = None


SCENARIOS = (
    Scenario("root-completes", "Reply with exactly LIVE_ROOT_DONE.", "Stop", marker="LIVE_ROOT_DONE"),
    Scenario("root-question", "Use AskUserQuestion to ask which color I prefer.", "PreToolUse", True),
    Scenario("root-approval", "Run: touch /Library/DanTermLiveRootApprovalFixture", "PermissionRequest", True),
    Scenario("root-elicitation", "Call the live_notification_fixture MCP tool now.", "Elicitation", True, marker="DANTERM_LIVE_ELICITATION"),
    Scenario("subagent-completes", "Delegate to the live-worker agent. It must reply LIVE_SUBAGENT_DONE, then you reply LIVE_ROOT_AFTER_SUBAGENT.", "SubagentStop", subagent=True, marker="LIVE_SUBAGENT_DONE"),
    Scenario("subagent-approval", "Delegate to live-worker and tell it to run: touch /Library/DanTermLiveSubagentApprovalFixture", "PermissionRequest", True, True),
    Scenario("subagent-elicitation", "Delegate to live-worker and tell it to call live_notification_fixture.", "Elicitation", True, True, "DANTERM_LIVE_ELICITATION"),
    Scenario("background-parking", "Start live-worker as background work. It must wait briefly using sleep, then reply LIVE_BACKGROUND_DONE. Wait for it and finally reply LIVE_ROOT_AFTER_BACKGROUND.", "Stop", marker="LIVE_ROOT_AFTER_BACKGROUND"),
)


def write_private(path: Path, data: str, executable: bool = False) -> None:
    path.write_text(data, encoding="utf-8")
    path.chmod(0o700 if executable else 0o600)


def terminal_sequences(data: bytes, kind: str) -> list[bytes]:
    return (OSC_777 if kind == "claude" else OSC_9).findall(data)


def sanitized_json_lines(path: Path) -> list[dict]:
    if not path.exists():
        return []
    result = []
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            value = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            value.pop("transcript_path", None)
            value.pop("cwd", None)
            result.append(value)
    return result


def event_matches(event: dict, scenario: Scenario) -> bool:
    if event.get("hook_event_name") != scenario.event:
        return False
    identity = event.get("agent_id") or event.get("agent_type")
    if scenario.subagent and not identity:
        return False
    if scenario.name == "root-question" and event.get("tool_name") not in ("AskUserQuestion", "request_user_input"):
        return False
    if scenario.marker and scenario.marker not in json.dumps(event, sort_keys=True):
        return False
    return True


def upstream_matches(kind: str, event: dict, scenario: Scenario) -> bool:
    if kind == "codex" and scenario.name.endswith("elicitation"):
        identity = event.get("agent_id") or event.get("agent_type")
        return (event.get("hook_event_name") == "PreToolUse"
                and "live_notification_fixture" in str(event.get("tool_name", ""))
                and (not scenario.subagent or bool(identity)))
    return event_matches(event, scenario)


def drive_pty(argv: list[str], env: dict[str, str], cwd: Path, capture: Path,
              ready: Callable[[bytes], bool], timeout: float) -> tuple[bytes, int | None]:
    pid, master = pty.fork()
    if pid == 0:
        os.chdir(cwd)
        os.execvpe(argv[0], argv, env)
    output = bytearray()
    deadline = time.monotonic() + timeout
    status = None
    try:
        while time.monotonic() < deadline:
            readable, _, _ = select.select([master], [], [], 0.1)
            if readable:
                try:
                    chunk = os.read(master, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                output.extend(chunk)
                for pattern, response in TERMINAL_QUERIES:
                    if pattern.search(chunk):
                        os.write(master, response)
                if ready(bytes(output)):
                    break
            done, child_status = os.waitpid(pid, os.WNOHANG)
            if done:
                status = os.waitstatus_to_exitcode(child_status)
                break
        else:
            raise TimeoutError(f"timed out after {timeout:.0f}s")
    finally:
        capture.write_bytes(output)
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
        os.close(master)
    return bytes(output), status


def hook_command(script: Path, log: Path) -> str:
    import shlex
    return f"{shlex.quote(sys.executable)} {shlex.quote(str(script))} --record-hook {shlex.quote(str(log))}"


def hook_entries(command: str, production: str | None = None) -> list[dict]:
    hooks = [{"type": "command", "command": command, "timeout": 10}]
    if production:
        hooks.insert(0, {"type": "command", "command": production, "timeout": 10})
    return [{"hooks": hooks}]


def configure_claude(root: Path, script: Path, repo: Path) -> tuple[dict[str, str], list[str]]:
    log = root / "events.jsonl"
    recorder = hook_command(script, log)
    production = str(repo / "integrations/claude-code/claude-notify-osc777.sh")
    hooks = {name: hook_entries(recorder, production if name in {"Stop", "PreToolUse", "PermissionRequest", "Elicitation"} else None)
             for name in ("Stop", "SubagentStart", "SubagentStop", "PreToolUse", "PermissionRequest", "Elicitation")}
    settings = root / "claude-settings.json"
    write_private(settings, json.dumps({"preferredNotifChannel": "notifications_disabled", "hooks": hooks}))
    mcp = root / "mcp.json"
    write_private(mcp, json.dumps({"mcpServers": {"live-notification-fixture": {
        "command": sys.executable, "args": [str(script), "--mcp-server"]}}}))
    agents = json.dumps({"live-worker": {"description": "Restricted live notification fixture worker",
        "prompt": "Never delegate. Follow only the requested fixture action, then stop.",
        "tools": ["Bash", "mcp__live-notification-fixture__live_notification_fixture"]}})
    env = os.environ.copy()
    argv = [shutil.which("claude") or "claude", "--setting-sources", "", "--settings", str(settings),
            "--strict-mcp-config", "--mcp-config", str(mcp), "--agents", agents,
            "--permission-mode", "manual", "--model", os.environ.get("DANTERM_CLAUDE_MODEL", "haiku")]
    return env, argv


def configure_codex(root: Path, script: Path) -> tuple[dict[str, str], list[str], Path]:
    codex_home = root / "codex-home"
    codex_home.mkdir(mode=0o700)
    (codex_home / "agents").mkdir(mode=0o700)
    source_home = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
    auth_source = source_home / "auth.json"
    if not auth_source.is_file():
        raise SetupFailure(f"Codex login missing: {auth_source}")
    auth_link = codex_home / "auth.json"
    auth_link.symlink_to(auth_source)
    try:
        log = root / "events.jsonl"
        hooks = {name: hook_entries(hook_command(script, log)) for name in
                 ("Stop", "SubagentStart", "SubagentStop", "PreToolUse", "PermissionRequest")}
        write_private(codex_home / "hooks.json", json.dumps({"hooks": hooks}))
        write_private(codex_home / "config.toml", """
approval_policy = "untrusted"
sandbox_mode = "workspace-write"

[agents.live-worker]
description = "Restricted live notification fixture worker"
config_file = "%s"

[tui]
notifications = ["agent-turn-complete", "approval-requested", "plan-mode-prompt"]
notification_method = "osc9"
notification_condition = "always"

[mcp_servers.live-notification-fixture]
command = "%s"
args = ["%s", "--mcp-server"]
""" % (str(codex_home / "agents/live-worker.toml").replace('"', '\\"'),
           sys.executable.replace('"', '\\"'), str(script).replace('"', '\\"')))
        write_private(codex_home / "agents/live-worker.toml", 'description = "Restricted live notification fixture worker"\ndeveloper_instructions = "Never delegate. Follow only the requested fixture action, then stop."\n')
    except BaseException:
        auth_link.unlink(missing_ok=True)
        raise
    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)
    argv = [shutil.which("codex") or "codex", "--dangerously-bypass-hook-trust", "--no-alt-screen", "-C", str(root / "workspace")]
    model = os.environ.get("DANTERM_CODEX_MODEL")
    if not model and (source_home / "config.toml").is_file():
        try:
            with open(source_home / "config.toml", "rb") as stream:
                configured = tomllib.load(stream).get("model")
            model = configured if isinstance(configured, str) else None
        except BaseException:
            auth_link.unlink(missing_ok=True)
            raise
    if model:
        argv += ["--model", model]
    return env, argv, auth_link


def run_scenario(kind: str, scenario: Scenario, suite_root: Path, script: Path, repo: Path) -> None:
    root = suite_root / f"{kind}-{scenario.name}"
    root.mkdir(mode=0o700)
    (root / "workspace").mkdir(mode=0o700)
    auth_link = None
    try:
        if kind == "claude":
            env, argv = configure_claude(root, script, repo)
        else:
            env, argv, auth_link = configure_codex(root, script)
        prompt = scenario.prompt
        if kind == "codex" and scenario.name == "root-question":
            prompt = "Use request_user_input to ask which color I prefer. Do not ask in plain text."
        argv.append(prompt)
        log = root / "events.jsonl"
        expected_kind = kind

        def ready(data: bytes) -> bool:
            events = sanitized_json_lines(log)
            upstream = any(upstream_matches(kind, event, scenario) for event in events)
            if scenario.name == "subagent-completes" and upstream:
                stop_index = next(i for i, event in enumerate(events) if event_matches(event, scenario))
                subagent_id = events[stop_index].get("agent_id")
                started = any(event.get("hook_event_name") == "SubagentStart"
                              and event.get("agent_id") == subagent_id for event in events[:stop_index])
                root_stopped = any(event.get("hook_event_name") == "Stop" and not event.get("agent_id")
                                   for event in events[stop_index + 1:])
                upstream = started and root_stopped
            if scenario.name == "background-parking":
                parked = any(event.get("hook_event_name") == "Stop" and any(
                    str(task.get("status", "")).lower() not in {"completed", "complete", "done", "succeeded", "failed", "errored", "cancelled", "canceled", "killed", "stopped"}
                    for task in event.get("background_tasks", [])) for event in events)
                upstream = upstream and parked
            if kind == "codex" and scenario.name.endswith("elicitation"):
                upstream = upstream and b"DANTERM_LIVE_ELICITATION" in data
            notifications = terminal_sequences(data, expected_kind)
            return upstream and bool(notifications)

        output, status = drive_pty(argv, env, root / "workspace", root / "pty.raw", ready,
                                   float(os.environ.get("DANTERM_AGENT_NOTIFICATION_TIMEOUT", "180")))
        events = sanitized_json_lines(log)
        matching = [event for event in events if upstream_matches(kind, event, scenario)]
        notifications = terminal_sequences(output, kind)
        infrastructure_text = output.lower()
        infrastructure_markers = (b"not logged in", b"authentication", b"quota", b"rate limit",
                                  b"network error", b"connection failed", b"unauthorized")
        if any(marker in infrastructure_text for marker in infrastructure_markers):
            raise SetupFailure(f"{scenario.name}: {kind} reported an authentication, network, or quota failure")
        if not matching:
            detail = "fixture marker/identity missing" if any(e.get("hook_event_name") == scenario.event for e in events) else f"missing {scenario.event}"
            raise ContractFailure(f"{scenario.name}: {detail}")
        if len(notifications) != 1:
            raise ContractFailure(f"{scenario.name}: expected exactly one OSC notification, got {len(notifications)}")
        if scenario.blocked and any(e.get("hook_event_name") == "Stop" and not e.get("agent_id") for e in events):
            raise ContractFailure(f"{scenario.name}: notification arrived only after root Stop")
        if scenario.name == "subagent-completes":
            stop_index = next((i for i, e in enumerate(events) if event_matches(e, scenario)), -1)
            subagent_id = events[stop_index].get("agent_id") if stop_index >= 0 else None
            start_index = next((i for i, e in enumerate(events[:stop_index])
                                if e.get("hook_event_name") == "SubagentStart"
                                and e.get("agent_id") == subagent_id), -1)
            root_index = next((i for i, e in enumerate(events) if i > stop_index and e.get("hook_event_name") == "Stop" and not e.get("agent_id")), -1)
            if start_index < 0:
                raise ContractFailure("subagent-completes: no preceding SubagentStart with matching identity")
            if root_index < 0:
                raise ContractFailure("subagent-completes: no later root Stop")
        if scenario.name == "background-parking":
            parked = [event for event in events if event.get("hook_event_name") == "Stop" and event.get("background_tasks")]
            if not parked:
                raise ContractFailure("background-parking: no active background-task evidence")
        if status not in (None, 0) and not scenario.blocked:
            raise SetupFailure(f"{scenario.name}: {kind} exited {status}")
        print(f"PASS {kind}: {scenario.name}")
    finally:
        if auth_link is not None:
            auth_link.unlink(missing_ok=True)


def version(binary: str) -> str:
    try:
        return subprocess.check_output([binary, "--version"], text=True, stderr=subprocess.STDOUT, timeout=10).strip()
    except (OSError, subprocess.SubprocessError) as error:
        raise SetupFailure(f"cannot run {binary} --version: {error}") from error


def record_hook(log_name: str) -> int:
    raw = sys.stdin.buffer.read()
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        payload = {"invalid_json": True}
    for key in ("transcript_path", "cwd"):
        payload.pop(key, None)
    with open(log_name, "a", encoding="utf-8") as stream:
        stream.write(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")
    return 0


def mcp_server() -> int:
    next_id = 9001
    while line := sys.stdin.buffer.readline():
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        method = message.get("method")
        request_id = message.get("id")
        if method == "initialize":
            result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "danterm-live-notification", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": [{"name": "live_notification_fixture", "description": "Request the fixed DanTerm live-test form", "inputSchema": {"type": "object", "properties": {}}}]}
        elif method == "tools/call":
            elicitation = {"jsonrpc": "2.0", "id": next_id, "method": "elicitation/create", "params": {
                "message": "DANTERM_LIVE_ELICITATION", "requestedSchema": {"type": "object", "properties": {"answer": {"type": "string", "title": "Fixture answer"}}, "required": ["answer"]}}}
            sys.stdout.write(json.dumps(elicitation) + "\n")
            sys.stdout.flush()
            next_id += 1
            continue
        else:
            if request_id is None:
                continue
            result = {}
        if request_id is not None:
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}) + "\n")
            sys.stdout.flush()
    return 0


def fake_child(kind: str, mode: str, auth_path: str | None, log_path: str | None) -> int:
    tty.setraw(0)
    os.write(1, b"\x1b[6n")
    response = os.read(0, 32)
    if b"1;1R" not in response:
        return 7
    if log_path:
        with open(log_path, "a", encoding="utf-8") as stream:
            stream.write(json.dumps({"hook_event_name": "PermissionRequest", "agent_id": "a1",
                                     "tool_name": "Bash", "cwd": "/secret"}) + "\n")
    if mode == "timeout":
        time.sleep(5)
        return 0
    if mode == "duplicate":
        seq = b"\x1b]777;notify;x;y\x07" if kind == "claude" else b"\x1b]9;y\x07"
        os.write(1, seq + seq)
    else:
        os.write(1, b"\x1b]777;notify;x;y\x07" if kind == "claude" else b"\x1b]9;y\x07")
    if auth_path:
        Path(auth_path).unlink(missing_ok=True)
    return 0


def run_live(selection: str) -> int:
    repo = Path(__file__).resolve().parent.parent
    script = Path(__file__).resolve()
    kinds = ("claude", "codex") if selection == "all" else (selection,)
    for kind in kinds:
        binary = shutil.which(kind)
        if not binary:
            raise SetupFailure(f"missing {kind} binary on PATH")
        if kind == "claude" and not shutil.which("jq"):
            raise SetupFailure("missing jq on PATH (required by the Claude production hook)")
        print(f"{kind}: {version(binary)}")
    retained = os.environ.get("DANTERM_AGENT_NOTIFICATION_ARTIFACTS")
    try:
        suite_root = Path(tempfile.mkdtemp(prefix="danterm-agent-notifications-", dir=retained))
    except OSError as error:
        raise SetupFailure(f"cannot create private artifact directory: {error}") from error
    suite_root.chmod(0o700)
    failed = False
    try:
        for kind in kinds:
            for scenario in SCENARIOS:
                if kind == "codex" and scenario.name == "background-parking":
                    continue
                run_scenario(kind, scenario, suite_root, script, repo)
    except (SetupFailure, ContractFailure, TimeoutError) as error:
        failed = True
        category = "SETUP" if isinstance(error, SetupFailure) else "CONTRACT"
        print(f"{category} FAILURE: {error}", file=sys.stderr)
        print(f"Sanitized failure artifacts: {suite_root}", file=sys.stderr)
        return 2 if category == "SETUP" else 1
    finally:
        for link in suite_root.glob("**/codex-home/auth.json"):
            link.unlink(missing_ok=True)
        if not failed and not os.environ.get("DANTERM_KEEP_AGENT_NOTIFICATION_ARTIFACTS"):
            shutil.rmtree(suite_root)
        elif not failed:
            print(f"Artifacts retained: {suite_root}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("selection", nargs="?", choices=("all", "claude", "codex"), default="all")
    parser.add_argument("--record-hook", metavar="PATH")
    parser.add_argument("--mcp-server", action="store_true")
    parser.add_argument("--fake-child", choices=("claude", "codex"))
    parser.add_argument("--fake-mode", choices=("ok", "duplicate", "timeout"), default="ok")
    parser.add_argument("--fake-auth")
    parser.add_argument("--fake-log")
    args = parser.parse_args()
    if args.record_hook:
        return record_hook(args.record_hook)
    if args.mcp_server:
        return mcp_server()
    if args.fake_child:
        return fake_child(args.fake_child, args.fake_mode, args.fake_auth, args.fake_log)
    try:
        return run_live(args.selection)
    except SetupFailure as error:
        print(f"SETUP FAILURE: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
