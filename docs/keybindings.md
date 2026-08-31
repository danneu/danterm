# Custom key bindings

Use Settings > Key Bindings, or add a `keybindings` object to the version 1
config file. An action that is absent uses its default. An array replaces all
defaults, and an empty array disables the action. Reset removes the override.

```json
{
  "schemaVersion": 1,
  "keybindings": {
    "tab.new": ["cmd+t"],
    "pane.focus-left": ["cmd+shift+h", "cmd+option+left"],
    "tab.jump": []
  }
}
```

A chord uses `cmd+ctrl+option+shift+key` order and must include Cmd, Control,
or Option. The key is the unshifted logical character for the active keyboard
layout; Shift belongs only in the modifier list. Named keys are `plus`,
`space`, `tab`, `enter`, `escape`, `backspace`, `delete`, `insert`, `left`,
`right`, `up`, `down`, `home`, `end`, `pageup`, `pagedown`, and `f1` through
`f20`. Fixed macOS and Cocoa shortcuts such as Undo, Copy, Paste, Hide, Quit,
Minimize, window cycling, and Settings (`cmd+,`) are reserved and cannot be
reassigned.

Configurable action ids are:

- Application: `app.open-config`, `app.reload-config`
- Editing: `edit.find`, `edit.find-next`, `edit.find-previous`
- View: `view.toggle-theme-browser`, `view.font-increase`,
  `view.font-decrease`, `view.font-reset`, `view.toggle-sidebar`,
  `view.toggle-alerts`
- Tabs: `tab.new`, `tab.new-at-end`, `tab.new-group`, `tab.rename`,
  `tab.clear-title`, `tab.next`, `tab.previous`, `tab.jump`,
  `tab.recent-older`, `tab.recent-newer`, `tab.color-red`,
  `tab.color-orange`, `tab.color-yellow`, `tab.color-green`, `tab.color-blue`,
  `tab.color-purple`, `tab.color-gray`, `tab.color-none`, `tab.clear-alerts`,
  `tab.toggle-todo`, `tab.close`
- Panes: `pane.split-right`, `pane.split-down`, `pane.toggle-zoom`,
  `pane.focus-left`, `pane.focus-down`, `pane.focus-up`, `pane.focus-right`,
  `pane.next-alert`, `pane.clear-alerts`, `pane.toggle-todo`, `pane.close`
