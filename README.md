# <img src="icon/raw-readme.svg" width="64" height="64" alt="DanTerm icon" align="center" style="vertical-align: middle;"> danterm

A macOS terminal built on ghostty with the behavior I want.

![DanTerm screenshot](docs/screenshot/screenshot1.png)

## Install

Download the latest `.dmg` from [Releases](https://github.com/danneu/danterm/releases/latest).

## Usage

Like any other terminal, you probably want to grant DanTerm.app these macOS permissions:

- Settings -> Privacy & Security -> Full Disk Access
- Settings -> Privacy & Security -> Developer Tools

## Non-negotiable features:

- Vertical tab sidebar
- Split panes
- Creating a tab/pane should use the cwd of the previous pane
- Highly visible terminal bell that remains until dismissed
- Notifications from panes toggle the originating pane when clicked

## Bonus features:

- Tabs can be grouped into collapsible sections
- Lightweight: Built with AppKit (Swift) on top of ghostty (zig)
- Launch terminal with specific layout/tabs/panes/commands: `--init <model.json>`
