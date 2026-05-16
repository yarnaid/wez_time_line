# Wez Time Line

WezTerm plugin that shows a right-side **timestamp gutter** with the wall-clock time each scrollback line was first observed. Inspired by iTerm2's *View → Show Timestamps*.

Enabled by default; toggle off/on with **Cmd+E**.

## Install

```lua
local wezterm = require 'wezterm'
local config = wezterm.config_builder()

local line_time = wezterm.plugin.require 'https://github.com/yarnaid/wez_time_line'
line_time.apply_to_config(config)

return config
```

For local development:

```lua
local line_time = wezterm.plugin.require 'file:///Users/yarnaid/projects/line_time'
```

`apply_to_config` appends the Cmd+E keybinding to `config.keys` and registers an `update-status` handler — it never overwrites existing config.

## Usage

A 10-cell-wide gutter pane is spawned to the right of every pane on startup and kept in sync on each `update-status` tick. New panes opened later acquire their own gutter on the next tick.

| Action | Effect |
|---|---|
| Press **Cmd+E** | Close every gutter pane (if currently shown), or reopen them all (if currently hidden). |

Toggle scope is **global** — all windows, all tabs, all panes — by design. The toggle state is stored in `wezterm.GLOBAL`, so an explicit "off" survives config reloads but resets to "on" when WezTerm is restarted.

## How it works

- The gutter is a real WezTerm pane running `sleep`, written to via `pane:inject_output`. WezTerm has no per-row decoration API for plugins, so a sibling pane is the closest faithful approximation to iTerm2's overlay.
- Timestamps come from diffing each pane's scrollback (`pane:get_logical_lines_as_text`) once per `update-status` tick. New lines since the previous tick are stamped with the current time.

## Limitations (v0)

- Timestamp resolution is one `update-status` tick (default ~1s); multiple lines emitted in the same tick share one timestamp. Panes spawned later acquire their gutter on the next tick (≤1s gap).
- Unix-only — the gutter child is `sleep`, not available by default on Windows.
- `pane:inject_output` does not work on multiplexer (remote) panes.
- TUIs (vim, htop, less) rewrite the visible region; the gutter will show whatever the diff observed, which may not align meaningfully with the redrawn content.
- No scroll synchronisation between the main pane and the gutter pane.

## Status

Experimental v0. See `CLAUDE.md` for design rationale and the locked architectural decisions.
