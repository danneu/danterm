#!/usr/bin/env python3
"""Convert adopted pinned Alacritty recordings into neutral replay fixtures."""

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
    "tmux_git_log": [],
    "tmux_htop": [],
    "underline": [],
    "vim_24bitcolors_bce": ["DanTerm retains explicit RGB foregrounds that equal Alacritty's configured default."],
    "vim_large_window_scroll": ["DanTerm retains explicit RGB foregrounds that equal Alacritty's configured default."],
    "vim_simple_edit": ["DanTerm retains explicit RGB foregrounds that equal Alacritty's configured default."],
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
APPLICATION_EXPECTATIONS = {
    "tmux_git_log": {"cursor": (22, 1), "cursorVisible": True, "mouseTracking": "off", "sgrMouseEncoding": False},
    "tmux_htop": {"cursor": (0, 0), "cursorVisible": False, "mouseTracking": "click", "sgrMouseEncoding": True},
    "vim_24bitcolors_bce": {"cursor": (55, 5), "cursorVisible": True, "mouseTracking": "off", "sgrMouseEncoding": False},
    "vim_large_window_scroll": {"cursor": (46, 5), "cursorVisible": True, "mouseTracking": "off", "sgrMouseEncoding": False},
    "vim_simple_edit": {"cursor": (2, 4), "cursorVisible": True, "mouseTracking": "off", "sgrMouseEncoding": False},
}
DEFAULT_FOREGROUNDS = {
    "vim_24bitcolors_bce": "rgb:238,238,238",
    "vim_large_window_scroll": "rgb:234,234,234",
    "vim_simple_edit": "rgb:234,234,234",
}
NAMED_COLOR_INDICES = {
    "Black": 0,
    "Red": 1,
    "Green": 2,
    "Yellow": 3,
    "Blue": 4,
    "Magenta": 5,
    "Cyan": 6,
    "White": 7,
    "BrightBlack": 8,
    "BrightRed": 9,
    "BrightGreen": 10,
    "BrightYellow": 11,
    "BrightBlue": 12,
    "BrightMagenta": 13,
    "BrightCyan": 14,
    "BrightWhite": 15,
}


def visible_rows(grid: dict, screen_lines: int) -> list[dict]:
    raw = grid["raw"]
    rows = raw["inner"]
    indices = [(raw["zero"] + offset) % len(rows) for offset in range(screen_lines)]
    return [rows[index] for index in reversed(indices)]


def viewport_text(grid: dict, screen_lines: int) -> str:
    def text(cell: dict) -> str:
        if "WIDE_CHAR_SPACER" in cell["flags"]:
            return ""
        scalar = " " if cell["c"] == "\t" else cell["c"]
        extra = cell.get("extra") or {}
        return scalar + "".join(extra.get("zerowidth", []))

    return "\n".join("".join(text(cell) for cell in row["inner"]) for row in visible_rows(grid, screen_lines))


def color_token(color: dict, default_name: str, default_override: str | None = None) -> str:
    if "Named" in color:
        name = color["Named"]
        if name == default_name:
            return default_override or "default"
        return f"indexed:{NAMED_COLOR_INDICES[name]}"
    rgb = color["Spec"]
    return f"rgb:{rgb['r']},{rgb['g']},{rgb['b']}"


def fixture_style(name: str, cell: dict) -> dict:
    flags = set(filter(None, cell["flags"].split(" | ")))
    attributes = [
        fixture
        for alacritty, fixture in [
            ("BOLD", "bold"),
            ("DIM", "dim"),
            ("ITALIC", "italic"),
            ("INVERSE", "reverse"),
            ("HIDDEN", "hidden"),
            ("STRIKEOUT", "strikethrough"),
        ]
        if alacritty in flags
    ]
    underline = "none"
    for flag, value in [
        ("UNDERLINE", "single"),
        ("DOUBLE_UNDERLINE", "double"),
        ("UNDERCURL", "curly"),
    ]:
        if flag in flags:
            underline = value
    return {
        "foreground": color_token(cell["fg"], "Foreground", DEFAULT_FOREGROUNDS.get(name)),
        "background": color_token(cell["bg"], "Background"),
        "attributes": attributes,
        "underline": underline,
    }


def cell_style_runs(name: str, grid: dict, screen_lines: int) -> list[dict]:
    runs = []
    for row_index, row in enumerate(visible_rows(grid, screen_lines)):
        cells = row["inner"]
        start = 0
        style = fixture_style(name, cells[0])
        for column in range(1, len(cells) + 1):
            next_style = fixture_style(name, cells[column]) if column < len(cells) else None
            if next_style != style:
                runs.append({
                    "row": row_index,
                    "startColumn": start,
                    "endColumn": column,
                    "style": style,
                })
                start = column
                style = next_style
    return runs


def application_expectation(name: str, grid: dict, screen_lines: int) -> dict:
    application = APPLICATION_EXPECTATIONS[name]
    cursor_row, cursor_column = application["cursor"]
    return {
        "viewportText": viewport_text(grid, screen_lines),
        "cellStyleRuns": cell_style_runs(name, grid, screen_lines),
        "cursor": {"row": cursor_row, "column": cursor_column, "pendingWrap": False},
        "cursorPresentation": {
            "isVisible": application["cursorVisible"],
            "shape": "block",
            "isBlinking": False,
        },
        "scrollbackCount": 0,
        "primaryHistoryContains": ["~/code/alacritty"],
        "alternateScreenActive": True,
        "inputModes": {
            "applicationCursorKeys": True,
            "applicationKeypad": True,
            "lineFeedNewLine": False,
            "focusReporting": False,
            "bracketedPaste": False,
            "mouseTracking": application["mouseTracking"],
            "sgrMouseEncoding": application["sgrMouseEncoding"],
            "kittyKeyboardFlags": 0,
        },
    }


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
                    "expect": (
                        application_expectation(name, grid, size["screen_lines"])
                        if name in APPLICATION_EXPECTATIONS
                        else ADAPTED_EXPECTATIONS.get(
                            name,
                            {"viewportText": viewport_text(grid, size["screen_lines"])},
                        )
                    ),
                },
            ],
        }
        (DESTINATION / f"{name}.json").write_text(json.dumps(fixture, indent=2) + "\n")


if __name__ == "__main__":
    main()
