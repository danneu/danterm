#!/usr/bin/env python3
"""Research 41's tab-switch latency reading (`T3`), at the ten-tab staging.

The control for Phase 3. A change that lets a hidden pane drop its swapchain
makes revealing that pane dearer, so what a reveal costs *before* any such
change has to be on the record first, measured on the staging the footprint
rows are taken on: ten inert tabs, 170x60, Menlo 13, one optimized slot.

Three cases, in the app's own clock:

- `revealHiddenTab` -- a switch to a tab whose pane is hidden but still owns a
  live swapchain (the state every non-selected tab is in after staging, `S3`).
  Latency is the app's `reveal` event to the first `attach` on that same pane.
- `warmVisibleTab` -- a switch that lands on the tab already selected. It is
  reported as the round trip of the request, because the app records no
  visibility transition at all for it: there is no pane to reveal, so the
  presentation half of the cost is not merely small, it is absent.
- `coldFirstPresentation` -- a new tab's first frame. Latency is the pane
  view's `create` event to its first `attach`. Each sample opens a tab and
  closes it again, so the staging the other two cases run on is unchanged.

A fourth case is the price of the work Phase 3 would add rather than a switch
the user can make today:

- `swapchainRebuildOnVisiblePane` -- a live pane throws its rotation away and
  the next frame allocates a fresh depth-3 swapchain and renders every row into
  it. Nothing forces that on a reveal at this revision, so it is measured where
  the app does force it: a theme change. Latency is the `rebuild` event to the
  `attach` that answers it.

The instrument is the app's own presentation trace (`DANTERM_PRESENTATION_EVENT_LOG`,
`app/TerminalPresentationEventSampler.swift`): one JSON line per pane event with
a monotonic timestamp, written from inside the process, so no screen capture and
no cross-process clock is in the path. The two timestamps of a reveal are taken
at the top of `SwiftTerminalSessionView.setVisible(true)` and immediately after
the `CATransaction` that assigns `layer.contents`.

    python3 scripts/research/41/tab-switch-latency.py [--samples 12]
        [--settle 5] [--pause 0.5] [--termwars ~/Code/termwars]

Staging is `ten-tab-footprint.py`'s, borrowed from termwars' adapter for the
same reason: the window geometry, the seeded font, and the 170x60 readback are
already calibrated there. The one thing this script adds is the trace, and the
adapter has no hook for a launch variable, so the launcher it calls is replaced
by a shim that appends `--pass-env DANTERM_PRESENTATION_EVENT_LOG` to the
staging launch. `--stop` passes through the shim unchanged.

Prints one JSON document: the commit, the staging readback, every sample of
every case with its own timestamps, per-case median and min-max, and a bound on
the instrument's own write cost. Save it under
`docs/research/41-baseline-memory-ten-tabs/readings/`.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKOUT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
TRACE_VARIABLE = "DANTERM_PRESENTATION_EVENT_LOG"
# How long one sample waits for the frame its action asked for. It is a hang
# guard, not a measurement: a reveal that takes this long has already been
# recorded by the trace, and the wait only decides when the script gives up.
FRAME_DEADLINE_SECONDS = 5.0
POLL_SECONDS = 0.005


def git(*arguments: str) -> str:
    return subprocess.run(
        ["git", "-C", CHECKOUT, *arguments], capture_output=True, text=True,
    ).stdout.strip()


class Trace:
    """Reads the app's presentation trace forward, one action at a time.

    Every sample asks for the events *its own* action produced, so the reader
    keeps a file offset rather than re-reading the whole log. A partial last
    line is left in the buffer for the next read, because the app appends while
    this runs and a JSON line can be split across two reads.
    """

    def __init__(self, path: str):
        self._path = path
        self._offset = 0
        self._partial = ""

    def drain(self) -> list[dict]:
        if not os.path.isfile(self._path):
            return []
        with open(self._path, encoding="utf-8") as document:
            document.seek(self._offset)
            text = document.read()
            self._offset = document.tell()
        text = self._partial + text
        lines = text.split("\n")
        self._partial = lines.pop()
        return [json.loads(line) for line in lines if line.strip()]

    def collect_until(self, satisfied, deadline: float) -> list[dict]:
        """Accumulates this action's events until the caller has what it needs.

        Returns whatever arrived when the deadline passes, so a sample that
        never got its frame is reported as an incomplete sample rather than
        raising and losing the samples already taken.
        """
        events: list[dict] = []
        while True:
            events.extend(self.drain())
            if satisfied(events) or time.monotonic() >= deadline:
                return events
            time.sleep(POLL_SECONDS)


def first_pair(events: list[dict], opening: str) -> tuple[int, int] | None:
    """The first `opening` event and the first `attach` on that same pane.

    Pairing is per pane because a switch touches two of them: the tab going
    away records a `hide`, and any other pane's frame in the same window must
    not be read as the answer to this reveal. An opening event with no frame
    after it does not end the search: a later opening in the same drain may
    still carry its `attach`.
    """
    for index, event in enumerate(events):
        if event.get("event") != opening:
            continue
        pane = event.get("pane")
        for later in events[index + 1:]:
            if later.get("pane") == pane and later.get("event") == "attach":
                return int(event["uptimeNanoseconds"]), int(later["uptimeNanoseconds"])
    return None


def summarize(samples: list[dict], key: str) -> dict:
    """Median and spread over the samples that actually carry the number.

    A sample whose frame never arrived is counted in `incomplete` and left out
    of the statistics, so `n` is always the count the median was taken over and
    an unmeasured sample can never read as a fast one.
    """
    values = [sample[key] for sample in samples if sample.get(key) is not None]
    if not values:
        return {"n": 0, "incomplete": len(samples), "status": "unmeasured"}
    return {
        "n": len(values),
        "incomplete": len(samples) - len(values),
        "medianNanoseconds": int(statistics.median(values)),
        "minNanoseconds": min(values),
        "maxNanoseconds": max(values),
        "status": "ok",
    }


def instrument_write_cost(path: str, writes: int = 200) -> dict:
    """Bounds the one instrument write that falls inside a measured interval.

    The trace writes one line when the reveal starts and one when the frame is
    attached; only the first is inside the interval the reveal case reports. It
    is timed here against the same file the app appends to, so the bound is the
    same filesystem and the same line size.
    """
    line = b'{"pane":0,"uptimeNanoseconds":123456789012,"event":"reveal"}\n'
    descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    costs = []
    try:
        for _ in range(writes):
            started = time.monotonic_ns()
            os.write(descriptor, line)
            costs.append(time.monotonic_ns() - started)
    finally:
        os.close(descriptor)
    return {
        "n": len(costs),
        "medianNanoseconds": int(statistics.median(costs)),
        "maxNanoseconds": max(costs),
        "note": "one such write falls inside a reveal-to-attach interval",
    }


def frontmost_application() -> str:
    """What owns the screen while the samples are taken, for the record."""
    try:
        finished = subprocess.run(
            [
                "osascript", "-e",
                'tell application "System Events" to return '
                "name of first application process whose frontmost is true",
            ],
            capture_output=True, text=True, timeout=15,
        )
        return finished.stdout.strip() or "unknown"
    except Exception as failure:
        return f"unknown: {type(failure).__name__}"


def launcher_shim(run_dir: str) -> str:
    """A stand-in launcher that forwards the trace variable into the slot.

    The termwars adapter calls the checkout's `dev-slot-launcher.py` with a
    fixed argument list and offers no way to add to it, so the adapter's public
    `launcher` attribute -- which exists for exactly this -- is pointed at this
    shim. It appends the one allowlisted `--pass-env` name to a staging launch
    and passes everything else -- `--stop` above all -- through untouched.
    """
    path = os.path.join(run_dir, "slot-launcher-with-trace.py")
    real = os.path.join(CHECKOUT, "scripts", "dev-slot-launcher.py")
    with open(path, "w", encoding="utf-8") as script:
        script.write(
            "import os, sys\n"
            f"arguments = sys.argv[1:]\n"
            'if "--release" in arguments:\n'
            f'    arguments += ["--pass-env", {TRACE_VARIABLE!r}]\n'
            f"os.execv(sys.executable, [sys.executable, {real!r}, *arguments])\n"
        )
    return path


def tabs_of(snapshot: dict, collect_panes) -> list[tuple[str, str]]:
    """Every (tabId, firstPaneId) in the instance, in group and tab order.

    The tree walk is the adapter's own, imported rather than rewritten: a
    second reader of the same payload is a second thing to get wrong, and the
    adapter's raises on a shape it does not know instead of returning an empty
    tab.
    """
    result = []
    for group in snapshot.get("groups") or []:
        for tab in group.get("tabs") or []:
            panes: list[str] = []
            collect_panes(tab.get("rootNode"), panes)
            result.append((tab["id"], panes[0]))
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--tabs", type=int, default=10)
    parser.add_argument("--samples", type=int, default=12)
    parser.add_argument("--settle", type=float, default=5.0)
    parser.add_argument(
        "--pause", type=float, default=0.5,
        help="quiet time between samples, so one action's frames cannot land in the next",
    )
    parser.add_argument(
        "--termwars",
        default=os.environ.get("TERMWARS_CHECKOUT", "~/Code/termwars"),
        help="the termwars checkout whose adapter stages the slot",
    )
    arguments = parser.parse_args(argv)

    termwars = os.path.expanduser(arguments.termwars)
    if not os.path.isdir(os.path.join(termwars, "termwars")):
        print(f"no termwars package under {termwars}", file=sys.stderr)
        return 2
    sys.path.insert(0, termwars)
    os.environ["DANTERM_CHECKOUT"] = CHECKOUT

    from termwars.adapters import danterm as danterm_adapter  # noqa: E402
    from termwars.runner import release_writers, reset_writers  # noqa: E402
    from termwars.trial import ARMS, TrialConfig  # noqa: E402

    arm = ARMS["tabs-empty-visible"]
    config = TrialConfig(tabs=arguments.tabs)

    if arguments.tabs < 2:
        # Every sample reveals a tab that is not the selected one; one tab means
        # there is nothing to reveal and the search for one would never end.
        print("--tabs must be 2 or more to reveal a hidden tab", file=sys.stderr)
        return 2

    run_root = os.path.join(CHECKOUT, ".run")
    os.makedirs(run_root, exist_ok=True)
    run_dir = tempfile.mkdtemp(prefix="r41-switch-", dir=run_root)
    trace_path = os.path.join(run_dir, "presentation-events.jsonl")
    os.environ[TRACE_VARIABLE] = trace_path
    adapter = danterm_adapter.DanTermAdapter(run_dir)
    adapter.launcher = launcher_shim(run_dir)
    problems = adapter.preflight_problems()
    if problems:
        for problem in problems:
            print(problem, file=sys.stderr)
        shutil.rmtree(run_dir, ignore_errors=True)
        return 1

    document: dict = {
        "research": "41",
        "task": "T3",
        "commit": git("rev-parse", "--short", "HEAD"),
        "dirty": bool(git("status", "--porcelain", "--untracked-files=no")),
        "arm": arm.name,
        "requestedGrid": [config.columns, config.rows],
        "tabs": config.tabs,
        "font": [config.fontFamily, config.fontSize],
        "settleSeconds": arguments.settle,
        "pauseSeconds": arguments.pause,
        "instrument": {
            "kind": "in-app presentation trace",
            "variable": TRACE_VARIABLE,
            "source": "app/TerminalPresentationEventSampler.swift",
            "clock": "DispatchTime.now().uptimeNanoseconds",
            "revealTimestamp": "SwiftTerminalSessionView.setVisible(true), before any reveal work",
            "attachTimestamp": "after the CATransaction that assigns layer.contents",
        },
    }
    try:
        reset_writers(run_dir, arm)
        adapter.launch(config, arm)
        adapter.open_units(config.tabs)
        adapter.request_grid(config.columns, config.rows)
        release_writers(run_dir, arm, config.tabs, log=lambda *_: None)
        document["achievedGrids"] = adapter.achieved_grids()
        document["version"] = adapter.version()
        time.sleep(arguments.settle)

        snapshot = json.loads(adapter.control("ls"))
        tabs = tabs_of(snapshot, danterm_adapter._collect_panes)
        document["stagedTabs"] = len(tabs)
        document["surfaces"] = json.loads(adapter.control("debug", "surfaces"))
        trace = Trace(trace_path)
        staged_events = trace.drain()  # staging's own events are not a sample
        # An instrument that never armed would report every sample as a missing
        # frame, which reads like a real answer. Staging opens and shows tabs, so
        # a trace that recorded nothing means the app is not writing the file.
        if not os.path.exists(trace_path) or not staged_events:
            raise RuntimeError(
                f"presentation trace recorded no staging events at {trace_path}; "
                f"is {TRACE_VARIABLE} honored by this build?"
            )

        reveal_samples = []
        selected = snapshot.get("selectedTabId")
        order = [pair for pair in tabs]
        cursor = 0
        for index in range(arguments.samples):
            while order[cursor % len(order)][0] == selected:
                cursor += 1
            tab_id, pane_id = order[cursor % len(order)]
            cursor += 1
            started = time.monotonic()
            adapter.control("pane", "focus", "--pane", pane_id)
            requested = time.monotonic()
            events = trace.collect_until(
                lambda seen: first_pair(seen, "reveal") is not None,
                deadline=started + FRAME_DEADLINE_SECONDS,
            )
            pair = first_pair(events, "reveal")
            reveal_samples.append({
                "index": index,
                "tabId": tab_id,
                "revealUptimeNanoseconds": pair[0] if pair else None,
                "attachUptimeNanoseconds": pair[1] if pair else None,
                "latencyNanoseconds": (pair[1] - pair[0]) if pair else None,
                "requestRoundTripNanoseconds": int((requested - started) * 1e9),
                "attachEvents": len(
                    [event for event in events if event.get("event") == "attach"]
                ),
                "events": [event["event"] for event in events],
            })
            selected = tab_id
            time.sleep(arguments.pause)

        warm_samples = []
        warm_pane = dict(tabs)[selected]
        for index in range(arguments.samples):
            started = time.monotonic()
            adapter.control("pane", "focus", "--pane", warm_pane)
            finished = time.monotonic()
            events = trace.drain()
            warm_samples.append({
                "index": index,
                "tabId": selected,
                "requestRoundTripNanoseconds": int((finished - started) * 1e9),
                "revealEvents": [
                    event for event in events if event.get("event") == "reveal"
                ],
                "events": [event["event"] for event in events],
            })
            time.sleep(arguments.pause)

        cold_samples = []
        group_id = (snapshot.get("groups") or [{}])[0].get("id")
        for index in range(arguments.samples):
            started = time.monotonic()
            opened = json.loads(adapter.control(
                "tab", "new", "--group", group_id, "--foreground", "--at-group-end",
            ))
            events = trace.collect_until(
                lambda seen: first_pair(seen, "create") is not None,
                deadline=started + FRAME_DEADLINE_SECONDS,
            )
            pair = first_pair(events, "create")
            cold_samples.append({
                "index": index,
                "tabId": opened["tab"]["id"],
                "createUptimeNanoseconds": pair[0] if pair else None,
                "attachUptimeNanoseconds": pair[1] if pair else None,
                "latencyNanoseconds": (pair[1] - pair[0]) if pair else None,
                "events": [event["event"] for event in events],
            })
            adapter.control("tab", "close", "--tab", opened["tab"]["id"])
            time.sleep(arguments.pause)
            trace.drain()  # the close, and the reveal of whatever took its place

        # What a reveal would cost if it had to build the buffers again. Nothing
        # forces that on a reveal today, so it is priced where the app does
        # already force it: a theme change throws the live rotation away, and
        # the frame that follows allocates a fresh depth-3 swapchain and renders
        # every row into it. That is the work a visible-lifetime release would
        # move onto every reveal.
        rebuild_samples = []
        current = json.loads(adapter.control("ls"))
        visible_pane = dict(
            tabs_of(current, danterm_adapter._collect_panes)
        )[current.get("selectedTabId")]
        themes = ["3024 Day", "3024 Night"]
        for index in range(arguments.samples):
            started = time.monotonic()
            adapter.control(
                "theme", "set", "--pane", visible_pane, themes[index % len(themes)]
            )
            events = trace.collect_until(
                lambda seen: first_pair(seen, "rebuild") is not None,
                deadline=started + FRAME_DEADLINE_SECONDS,
            )
            pair = first_pair(events, "rebuild")
            rebuild_samples.append({
                "index": index,
                "paneId": visible_pane,
                "rebuildUptimeNanoseconds": pair[0] if pair else None,
                "attachUptimeNanoseconds": pair[1] if pair else None,
                "latencyNanoseconds": (pair[1] - pair[0]) if pair else None,
                "events": [event["event"] for event in events],
            })
            time.sleep(arguments.pause)
        adapter.control("theme", "set", "--pane", visible_pane, "--clear")
        trace.drain()

        after = json.loads(adapter.control("ls"))
        document["tabsAfter"] = len(tabs_of(after, danterm_adapter._collect_panes))
        document["frontmostApplication"] = frontmost_application()
        document["cases"] = {
            "revealHiddenTab": {
                "samples": reveal_samples,
                **summarize(reveal_samples, "latencyNanoseconds"),
            },
            "warmVisibleTab": {
                "samples": warm_samples,
                "revealEventCount": sum(
                    len(sample["revealEvents"]) for sample in warm_samples
                ),
                **summarize(warm_samples, "requestRoundTripNanoseconds"),
            },
            "coldFirstPresentation": {
                "samples": cold_samples,
                **summarize(cold_samples, "latencyNanoseconds"),
            },
            "swapchainRebuildOnVisiblePane": {
                "samples": rebuild_samples,
                **summarize(rebuild_samples, "latencyNanoseconds"),
            },
        }
        document["instrumentWriteCost"] = instrument_write_cost(
            os.path.join(run_dir, "write-cost-probe.jsonl")
        )
        document["environment"] = adapter.environment_notes()
        document["status"] = "ok"
    except Exception as failure:  # recorded, never dropped
        document["status"] = "failed"
        document["error"] = f"{type(failure).__name__}: {failure}"
    finally:
        adapter.quit()
        shutil.rmtree(run_dir, ignore_errors=True)

    print(json.dumps(document, indent=2))
    return 0 if document["status"] == "ok" else 1


if __name__ == "__main__":
    raise SystemExit(main())
