#!/usr/bin/env python3
"""Convert the pinned Milestone 6 Alacritty recordings into neutral replay fixtures."""

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "references/alacritty/alacritty_terminal/tests/ref"
DESTINATION = ROOT / "lib/TerminalCore/Tests/TerminalCoreTests/Fixtures/alacritty"
PIN = "852e971cddfabe222d2d5bcda466e130f53af207"
CASES = {
    "alt_reset": [],
    "clear_underline": [],
    "colored_reset": [],
    "colored_underline": ["DanTerm retains colors semantically instead of resolving Alacritty palette RGB values."],
    "fish_cc": [],
    "history": [],
    "saved_cursor": ["DanTerm ignores unpromised legacy G0 character-set state during cursor restore."],
    "saved_cursor_alt": ["DanTerm ignores unpromised legacy G0 character-set state during cursor restore."],
    "scroll_in_region_up_preserves_history": ["DanTerm exposes bounded-scroll behavior through primary history rather than Alacritty's ring layout."],
    "sgr": [],
    "tab_rendering": ["DanTerm normalizes tab spans to public cell text rather than Alacritty's tab template cells."],
    "underline": [],
    "wrapline_alt_toggle": [],
    "zsh_tab_completion": [],
}
ADAPTED_EXPECTATIONS = {
    "colored_underline": {
        "viewportContains": ["UNDERLINEDOUBLEUh̷̗ERCURLDOTTEDDASHEDNOT_COLORED_DASH"],
    },
    "saved_cursor": {
        "viewportContains": [" xxxst", "   xxx", "[undeadleech@archhq saved_cursor]$ exit"],
        "viewportExcludes": ["⎽├", "│││"],
    },
    "saved_cursor_alt": {
        "viewportContains": [" xxxst", "[undeadleech@archhq saved_cursor_alt]$ exit"],
        "viewportExcludes": ["⎽├", "│││"],
    },
}


def viewport_text(grid: dict, screen_lines: int) -> str:
    raw = grid["raw"]
    rows = raw["inner"]
    indices = [(raw["zero"] + offset) % len(rows) for offset in range(screen_lines)]
    visible = [rows[index] for index in reversed(indices)]
    def text(cell: dict) -> str:
        if "WIDE_CHAR_SPACER" in cell["flags"]:
            return ""
        scalar = " " if cell["c"] == "\t" else cell["c"]
        extra = cell.get("extra") or {}
        return scalar + "".join(extra.get("zerowidth", []))

    return "\n".join("".join(text(cell) for cell in row["inner"]) for row in visible)


def main() -> None:
    DESTINATION.mkdir(parents=True, exist_ok=True)
    for name, deviations in CASES.items():
        source = SOURCE / name
        size = json.loads((source / "size.json").read_text())
        grid = json.loads((source / "grid.json").read_text())
        recording = (source / "alacritty.recording").read_bytes()
        fixture = {
            "version": 1,
            "provenance": {
                "source": "alacritty",
                "url": f"https://github.com/alacritty/alacritty/blob/{PIN}/alacritty_terminal/tests/ref/{name}/alacritty.recording",
                "pinnedCommit": PIN,
                "upstreamCase": name,
                "license": "Apache-2.0",
                "licenseNotice": "LICENSE.alacritty.txt",
                "recordedDeviations": deviations,
            },
            "initial": {"columns": size["columns"], "rows": size["screen_lines"]},
            "events": [
                {"type": "feed", "hex": recording.hex()},
                {
                    "type": "expect",
                    "expect": ADAPTED_EXPECTATIONS.get(
                        name,
                        {"viewportText": viewport_text(grid, size["screen_lines"])},
                    ),
                },
            ],
        }
        (DESTINATION / f"{name}.json").write_text(json.dumps(fixture, indent=2) + "\n")


if __name__ == "__main__":
    main()
