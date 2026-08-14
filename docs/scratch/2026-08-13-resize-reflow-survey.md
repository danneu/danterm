# Width Reflow Survey

## Question

Why did a narrow-then-wide round trip move a viewport whose cursor was above
never-written trailing blank rows?

The probe used the same shape in each terminal: retained output above a live
screen, written rows near the top, a cursor above the bottom, and blank rows
below it. It recorded the narrow layout and then widened back without output.
Source reading selected the probe and explained the result; the probe, not the
source shape, established behavior.

## Result

The nine terminals split by data model.

| Terminal | Reflow treatment | Probe result |
|---|---|---|
| ghostty | Trims trailing blank rows before refolding | Loses the original layout |
| kitty | Excludes empty bottom lines and trims blank cells | Loses the original layout |
| wezterm | Refolds only visible line cells | Loses the original layout |
| foot | Rebuilds a bottom-aligned reflow destination | One-resize-wide fence around the loss |
| vte | Rewraps the retained ring and restates markers | One-resize-wide fence around the loss |
| libvterm | Rebuilds screen rows from measured line height | One-resize-wide fence around the loss |
| alacritty | Resizes one grid whose history/live split is derived | Self-inverse without resize state |
| tmux | Reflows the whole grid and derives history size | Self-inverse without resize state |
| iTerm2 | Stores logical lines and projects wrapped rows by width | Self-inverse without resize state |

The relevant source entry points are
`references/ghostty/src/terminal/PageList.zig#reflowRow`,
`references/kitty/kitty/resize.c#exclude_empty_lines_at_bottom`,
`references/kitty/kitty/resize.c#init_src_line`,
`references/wezterm/term/src/screen.rs#Screen::rewrap_lines`,
`references/foot/grid.c#grid_resize_and_reflow`,
`references/vte/src/ring.cc#Ring::rewrap`,
`references/libvterm/src/screen.c#resize_buffer`,
`references/alacritty/alacritty_terminal/src/grid/resize.rs#Grid::resize`,
`references/tmux/grid.c#grid_reflow`, and
`references/iterm2/sources/LineBuffer.m#LineBuffer`.

## Conclusion

Remembering a viewport across selected resize events can fence the loss, but it
cannot make a lossy refold self-inverse. DanTerm should preserve trailing blank
rows as part of the live layout, append them before it computes the viewport
deficit, and derive the history/live seam from the resulting stream. The only
required loss is a trailing-blank clamp when preserving all blanks would hide
the cursor.
