#!/usr/bin/env python3
"""Opt-in live compatibility tests for Claude and Codex terminal notifications."""

from __future__ import annotations

import argparse
import errno
import fcntl
import json
import os
import pty
import re
import select
import shutil
import signal
import subprocess
import struct
import sys
import tempfile
import termios
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
    (re.compile(rb"\x1b\]10;\?\x1b\\"), b"\x1b]10;rgb:ffff/ffff/ffff\x1b\\"),
    (re.compile(rb"\x1b\]11;\?\x1b\\"), b"\x1b]11;rgb:0000/0000/0000\x1b\\"),
)
CSI_SEQUENCE = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]")
INFRASTRUCTURE_MARKERS = (b"notloggedin", b"authentication", b"quota", b"ratelimit",
                          b"networkerror", b"connectionfailed", b"unauthorized",
                          b"deprecatedsoon")


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


@dataclass
class ReadinessState:
    """Tracks when stable upstream evidence first appeared for a scenario."""

    upstream_at: float | None = None


SCENARIOS = (
    Scenario("root-completes", "Reply with exactly LIVE_ROOT_DONE.", "Stop", marker="LIVE_ROOT_DONE"),
    Scenario("root-question", "Use the AskUserQuestion tool now to ask which color I prefer. Do not ask in plain text.", "PreToolUse", True),
    Scenario("root-approval", "Use the Bash tool now to run exactly: touch /Library/DanTermLiveRootApprovalFixture. Do not ask a question or mention sudo; the CLI permission UI is the required confirmation.", "PermissionRequest", True),
    Scenario("root-elicitation", "Call the live_notification_fixture MCP tool now. Do not request input in plain text.", "Elicitation", True, marker="DANTERM_LIVE_ELICITATION"),
    Scenario("subagent-completes", "Use the Agent tool with subagent_type live-worker to delegate exactly this task: Reply with exactly LIVE_SUBAGENT_DONE and do nothing else. You must call the Agent tool; do not perform the task yourself. Wait for it to finish, then reply with exactly LIVE_ROOT_AFTER_SUBAGENT.", "SubagentStop", subagent=True, marker="LIVE_SUBAGENT_DONE"),
    Scenario("subagent-approval", "Use the Agent tool with subagent_type live-worker to delegate exactly this task: Run the Bash command touch /Library/DanTermLiveSubagentApprovalFixture. You must call the Agent tool; do not run the command yourself.", "PermissionRequest", True, True),
    Scenario("subagent-elicitation", "Use the Agent tool with subagent_type live-worker to delegate exactly this task: Call the live_notification_fixture MCP tool. You must call the Agent tool; do not call the MCP tool yourself.", "Elicitation", True, True, "DANTERM_LIVE_ELICITATION"),
    Scenario("background-parking", "Use the Agent tool with subagent_type live-worker to start background work with this exact task: Wait briefly using sleep, then reply LIVE_BACKGROUND_DONE. You must call the Agent tool with background execution; do not perform the task yourself. Wait for it and finally reply LIVE_ROOT_AFTER_BACKGROUND.", "Stop", marker="LIVE_ROOT_AFTER_BACKGROUND"),
)


def claude_scenario_tool_args(scenario: Scenario) -> list[str]:
    tool_by_scenario = {
        "root-question": "AskUserQuestion",
        "root-approval": "Bash",
        "subagent-completes": "Agent",
        "subagent-approval": "Agent,Bash",
        "subagent-elicitation": (
            "Agent,mcp__live-notification-fixture__live_notification_fixture"
        ),
        "background-parking": "Agent,Bash",
    }
    tool = tool_by_scenario.get(scenario.name)
    return [f"--tools={tool}"] if tool else []


def claude_worker_tools(scenario: Scenario) -> list[str]:
    if scenario.name in {"subagent-approval", "background-parking"}:
        return ["Bash"]
    if scenario.name == "subagent-elicitation":
        return ["mcp__live-notification-fixture__live_notification_fixture"]
    return []


def write_private(path: Path, data: str, executable: bool = False) -> None:
    path.write_text(data, encoding="utf-8")
    path.chmod(0o700 if executable else 0o600)


def terminal_sequences(data: bytes, kind: str) -> list[bytes]:
    return (OSC_777 if kind == "claude" else OSC_9).findall(data)


def normalized_screen(data: bytes) -> bytes:
    return re.sub(rb"\s+", b"", CSI_SEQUENCE.sub(b"", data)).lower()


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
    if scenario.subagent and not identity and scenario.name != "subagent-elicitation":
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


def has_active_background_task(event: dict) -> bool:
    terminal_statuses = {"completed", "complete", "done", "succeeded", "failed", "errored",
                         "cancelled", "canceled", "killed", "stopped"}
    return any(str(task.get("status", "")).lower() not in terminal_statuses
               for task in event.get("background_tasks", []))


def has_active_subagent_at(events: list[dict], index: int) -> bool:
    active: set[str] = set()
    for event in events[:index]:
        identity = event.get("agent_id") or event.get("agent_type")
        if not identity:
            continue
        if event.get("hook_event_name") == "SubagentStart":
            active.add(str(identity))
        elif event.get("hook_event_name") == "SubagentStop":
            active.discard(str(identity))
    return bool(active)


def root_stop_is_parked(events: list[dict], index: int) -> bool:
    return has_active_background_task(events[index]) or has_active_subagent_at(events, index)


def has_identified_subagent_elicitation(events: list[dict], scenario: Scenario) -> bool:
    elicitation_index = next((index for index, event in enumerate(events)
                              if event_matches(event, scenario)), -1)
    if elicitation_index < 0:
        return False
    return any(event.get("hook_event_name") == "PreToolUse"
               and "live_notification_fixture" in str(event.get("tool_name", ""))
               and bool(event.get("agent_id") or event.get("agent_type"))
               for event in events[:elicitation_index])


def has_codex_elicitation_dialog(events: list[dict], scenario: Scenario) -> bool:
    """Recognize Codex's blocked MCP form from lifecycle evidence, not screen text."""
    return any(event.get("hook_event_name") == "PermissionRequest"
               and "live_notification_fixture" in str(event.get("tool_name", ""))
               and (not scenario.subagent
                    or bool(event.get("agent_id") or event.get("agent_type")))
               for event in events)


def has_required_upstream(kind: str, events: list[dict], scenario: Scenario) -> bool:
    upstream = any(upstream_matches(kind, event, scenario) for event in events)
    if kind == "codex" and scenario.name.endswith("elicitation"):
        upstream = upstream and has_codex_elicitation_dialog(events, scenario)
    if kind == "claude" and scenario.name == "subagent-elicitation":
        upstream = upstream and has_identified_subagent_elicitation(events, scenario)
    if scenario.name == "subagent-completes" and upstream:
        stop_index = next(i for i, event in enumerate(events) if event_matches(event, scenario))
        subagent_id = events[stop_index].get("agent_id")
        started = any(event.get("hook_event_name") == "SubagentStart"
                      and event.get("agent_id") == subagent_id for event in events[:stop_index])
        root_stopped = any(event.get("hook_event_name") == "Stop" and not event.get("agent_id")
                           for event in events[stop_index + 1:])
        upstream = started and root_stopped
    if scenario.name == "background-parking":
        parked = any(event.get("hook_event_name") == "Stop"
                     and root_stop_is_parked(events, index)
                     for index, event in enumerate(events))
        upstream = upstream and parked
    return upstream


def terminal_root_stop_before_upstream(kind: str, events: list[dict], scenario: Scenario) -> bool:
    if has_required_upstream(kind, events, scenario):
        return False
    return any(event.get("hook_event_name") == "Stop"
               and not event.get("agent_id")
               and not root_stop_is_parked(events, index)
               for index, event in enumerate(events))


def scenario_is_ready(kind: str, scenario: Scenario, log: Path, data: bytes,
                      state: ReadinessState, now: float,
                      notification_grace: float) -> bool:
    """Synchronize on lifecycle evidence and bound missing-notification failures."""
    if any(marker in normalized_screen(data) for marker in INFRASTRUCTURE_MARKERS):
        return True
    events = sanitized_json_lines(log)
    upstream = has_required_upstream(kind, events, scenario)
    if terminal_root_stop_before_upstream(kind, events, scenario):
        raise ContractFailure(
            f"{scenario.name}: root completed before required {scenario.event} evidence")
    notifications = terminal_sequences(data, kind)
    if upstream and notifications:
        return True
    if upstream:
        if state.upstream_at is None:
            state.upstream_at = now
        elif now - state.upstream_at >= notification_grace:
            raise ContractFailure(
                f"{scenario.name}: notification missing {notification_grace:g}s after "
                f"{scenario.event} evidence")
    return False


def signal_child(pid: int, child_signal: signal.Signals) -> None:
    """Signal the PTY process tree, falling back when macOS denies group signaling."""
    try:
        os.killpg(pid, child_signal)
    except PermissionError:
        try:
            os.kill(pid, child_signal)
        except (ProcessLookupError, PermissionError):
            pass
    except ProcessLookupError:
        pass


def drive_pty(argv: list[str], env: dict[str, str], cwd: Path, capture: Path,
              ready: Callable[[bytes], bool], timeout: float) -> tuple[bytes, int | None]:
    pid, master = pty.fork()
    if pid == 0:
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        os.chdir(cwd)
        os.execvpe(argv[0], argv, env)
    output = bytearray()
    deadline = time.monotonic() + timeout
    status = None
    capture_stream = capture.open("wb")
    accepted_owned_workspace = False
    answered_queries: set[int] = set()
    try:
        while time.monotonic() < deadline:
            if ready(bytes(output)):
                break
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
                capture_stream.write(chunk)
                capture_stream.flush()
                for query_index, (pattern, response) in enumerate(TERMINAL_QUERIES):
                    if query_index not in answered_queries and pattern.search(bytes(output)):
                        os.write(master, response)
                        answered_queries.add(query_index)
                if not accepted_owned_workspace:
                    plain = normalized_screen(bytes(output))
                    claude_trust = b"yes,itrustthisfolder" in plain and b"no,exit" in plain
                    codex_trust = (b"doyoutrustthecontentsofthisdirectory?" in plain
                                   and b"1.yes,continue" in plain and b"2.no,quit" in plain)
                    if claude_trust or codex_trust:
                        os.write(master, b"\r")
                        accepted_owned_workspace = True
                if ready(bytes(output)):
                    break
            done, child_status = os.waitpid(pid, os.WNOHANG)
            if done:
                status = os.waitstatus_to_exitcode(child_status)
                break
        else:
            raise TimeoutError(f"timed out after {timeout:.0f}s")
    finally:
        capture_stream.close()
        signal_child(pid, signal.SIGTERM)
        cleanup_deadline = time.monotonic() + 2
        while True:
            try:
                done, _ = os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                break
            except KeyboardInterrupt:
                signal_child(pid, signal.SIGKILL)
                raise
            if done:
                break
            if time.monotonic() >= cleanup_deadline:
                signal_child(pid, signal.SIGKILL)
                break
            time.sleep(0.05)
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


def configure_claude(root: Path, script: Path, repo: Path,
                     scenario: Scenario | None = None) -> tuple[dict[str, str], list[str]]:
    log = root / "events.jsonl"
    recorder = hook_command(script, log)
    production = str(repo / "integrations/claude-code/claude-notify-osc777.sh")
    hooks = {name: hook_entries(recorder, production if name in {"Stop", "PreToolUse", "PermissionRequest", "Elicitation"} else None)
             for name in ("Stop", "SubagentStart", "SubagentStop", "PreToolUse", "PermissionRequest", "Elicitation")}
    settings = root / "claude-settings.json"
    write_private(settings, json.dumps({
        "preferredNotifChannel": "notifications_disabled",
        "permissions": {"allow": [
            "mcp__live-notification-fixture__live_notification_fixture",
            "Bash(sleep:*)",
        ]},
        "hooks": hooks,
    }))
    mcp = root / "mcp.json"
    write_private(mcp, json.dumps({"mcpServers": {"live-notification-fixture": {
        "command": sys.executable, "args": [str(script), "--mcp-server"]}}}))
    worker_tools = (claude_worker_tools(scenario) if scenario else
                    ["Bash", "mcp__live-notification-fixture__live_notification_fixture"])
    agents = json.dumps({"live-worker": {"description": "Restricted live notification fixture worker",
        "prompt": "Never delegate. Follow only the requested fixture action, then stop. Call the requested tool immediately. Do not ask for plain-text confirmation; the CLI permission UI is the confirmation mechanism.",
        "tools": worker_tools}})
    env = os.environ.copy()
    argv = [shutil.which("claude") or "claude", "--setting-sources", "", "--settings", str(settings),
            "--strict-mcp-config", "--mcp-config", str(mcp), "--agents", agents,
            "--permission-mode", "manual", "--model", os.environ.get("DANTERM_CLAUDE_MODEL", "haiku")]
    return env, argv


def configure_codex(root: Path, script: Path,
                    scenario: Scenario | None = None) -> tuple[dict[str, str], list[str], Path]:
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
        approval_policy = ("never" if scenario and scenario.name.endswith("elicitation")
                           else "untrusted")
        write_private(codex_home / "config.toml", """
approval_policy = "%s"
sandbox_mode = "workspace-write"

[features]
plugins = false
remote_plugin = false
default_mode_request_user_input = true

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
""" % (approval_policy,
           str(codex_home / "agents/live-worker.toml").replace('"', '\\"'),
           sys.executable.replace('"', '\\"'), str(script).replace('"', '\\"')))
        write_private(codex_home / "agents/live-worker.toml", 'name = "live-worker"\ndescription = "Restricted live notification fixture worker"\ndeveloper_instructions = "Never delegate. Follow only the requested fixture action, then stop."\n')
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
    print(f"RUN  {kind}: {scenario.name}", flush=True)
    try:
        if kind == "claude":
            env, argv = configure_claude(root, script, repo, scenario)
            argv += claude_scenario_tool_args(scenario)
        else:
            env, argv, auth_link = configure_codex(root, script, scenario)
        prompt = scenario.prompt
        if kind == "codex" and scenario.name == "root-question":
            prompt = "Use request_user_input to ask which color I prefer. Do not ask in plain text."
        argv.append(prompt)
        log = root / "events.jsonl"
        readiness = ReadinessState()
        notification_grace = float(os.environ.get(
            "DANTERM_AGENT_NOTIFICATION_GRACE", "5"))

        def ready(data: bytes) -> bool:
            return scenario_is_ready(kind, scenario, log, data, readiness,
                                     time.monotonic(), notification_grace)

        output, status = drive_pty(argv, env, root / "workspace", root / "pty.raw", ready,
                                   float(os.environ.get("DANTERM_AGENT_NOTIFICATION_TIMEOUT", "180")))
        events = sanitized_json_lines(log)
        matching = [event for event in events if upstream_matches(kind, event, scenario)]
        notifications = terminal_sequences(output, kind)
        infrastructure_text = normalized_screen(output)
        if any(marker in infrastructure_text for marker in INFRASTRUCTURE_MARKERS):
            raise SetupFailure(
                f"{scenario.name}: {kind} reported a startup, authentication, network, "
                "or quota failure")
        if not matching:
            detail = "fixture marker/identity missing" if any(e.get("hook_event_name") == scenario.event for e in events) else f"missing {scenario.event}"
            raise ContractFailure(f"{scenario.name}: {detail}")
        if kind == "claude" and scenario.name == "subagent-elicitation" \
                and not has_identified_subagent_elicitation(events, scenario):
            raise ContractFailure("subagent-elicitation: no preceding MCP call with subagent identity")
        if len(notifications) != 1:
            raise ContractFailure(f"{scenario.name}: expected exactly one OSC notification, got {len(notifications)}")
        root_stops = [(index, event) for index, event in enumerate(events)
                      if event.get("hook_event_name") == "Stop" and not event.get("agent_id")]
        blocking_root_stops = ([event for index, event in root_stops
                                if not root_stop_is_parked(events, index)]
                               if scenario.subagent else [event for _, event in root_stops])
        if scenario.blocked and blocking_root_stops:
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
            parked = [event for index, event in enumerate(events)
                      if event.get("hook_event_name") == "Stop"
                      and root_stop_is_parked(events, index)]
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
    if mode == "geometry" and os.get_terminal_size(0) != os.terminal_size((80, 24)):
        return 9
    os.write(1, b"\x1b[6n\x1b]10;?\x1b\\\x1b]11;?\x1b\\")
    response = bytearray()
    while not all(marker in response for marker in (b"1;1R", b"10;rgb:", b"11;rgb:")):
        chunk = os.read(0, 128)
        if not chunk:
            return 7
        response.extend(chunk)
    def write_fake_log() -> None:
        if not log_path:
            return
        with open(log_path, "a", encoding="utf-8") as stream:
            stream.write(json.dumps({"hook_event_name": "PermissionRequest", "agent_id": "a1",
                                     "tool_name": "Bash", "cwd": "/secret"}) + "\n")
    if mode != "sync":
        write_fake_log()
    if mode == "trust":
        if kind == "claude":
            os.write(1, b"\x1b[7GYes,\x1b[12GI\x1b[14Gtrust\x1b[20Gthis\x1b[25Gfolder\r\n"
                        b"\x1b[7GNo,\x1b[11Gexit\r\n")
        else:
            os.write(1, b"\x1b[3GDo\x1b[6Gyou\x1b[10Gtrust\x1b[16Gthe\x1b[20Gcontents\x1b[29Gof"
                        b"\x1b[32Gthis\x1b[37Gdirectory?\r\n\x1b[3G1. Yes, continue\r\n"
                        b"\x1b[3G2. No, quit\r\n")
        if b"\r" not in os.read(0, 8):
            return 8
    if mode == "timeout":
        time.sleep(5)
        return 0
    if mode == "duplicate":
        seq = b"\x1b]777;notify;x;y\x07" if kind == "claude" else b"\x1b]9;y\x07"
        os.write(1, seq + seq)
    else:
        os.write(1, b"\x1b]777;notify;x;y\x07" if kind == "claude" else b"\x1b]9;y\x07")
    if mode == "sync":
        time.sleep(0.15)
        write_fake_log()
        time.sleep(1)
    if auth_path:
        Path(auth_path).unlink(missing_ok=True)
    return 0


def sanitize_failure_artifacts(suite_root: Path) -> None:
    """Retain only per-scenario sanitized events and raw PTY captures."""
    retained_names = {"events.jsonl", "pty.raw"}
    for base, directories, files in os.walk(suite_root, topdown=False, followlinks=False):
        base_path = Path(base)
        for name in files:
            path = base_path / name
            retain = name in retained_names and path.parent.parent == suite_root
            if not retain:
                path.unlink(missing_ok=True)
        for name in directories:
            path = base_path / name
            if path.is_symlink():
                path.unlink(missing_ok=True)
                continue
            try:
                path.rmdir()
            except OSError:
                pass


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
    except KeyboardInterrupt:
        failed = True
        print(f"\nINTERRUPTED: sanitized artifacts retained at {suite_root}",
              file=sys.stderr)
        return 130
    finally:
        for link in suite_root.glob("**/codex-home/auth.json"):
            link.unlink(missing_ok=True)
        if failed:
            try:
                sanitize_failure_artifacts(suite_root)
            except OSError as error:
                print(f"WARNING: could not fully sanitize failure artifacts: {error}",
                      file=sys.stderr)
        elif not os.environ.get("DANTERM_KEEP_AGENT_NOTIFICATION_ARTIFACTS"):
            shutil.rmtree(suite_root)
        else:
            print(f"Artifacts retained: {suite_root}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("selection", nargs="?", choices=("all", "claude", "codex"), default="all")
    parser.add_argument("--record-hook", metavar="PATH")
    parser.add_argument("--mcp-server", action="store_true")
    parser.add_argument("--fake-child", choices=("claude", "codex"))
    parser.add_argument("--fake-mode", choices=("ok", "duplicate", "timeout", "trust", "sync", "geometry"), default="ok")
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
