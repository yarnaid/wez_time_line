# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

WezTerm plugin (Lua) that reproduces **iTerm2's "Show Timestamps" overlay** — a togglable right-side column showing the wall-clock time of each terminal row, separated from content by a thin vertical rule. Toggle binding: **Cmd+E** (matches iTerm2's default).

**Note:** `~/.claude/rules/frontend.md` says "use Dash (Python) for frontend" — that rule does **not** apply here. This is a terminal-emulator plugin, not a web UI; WezTerm plugins must be Lua. Project-level intent overrides the global rule.

## Status

Greenfield — no source files yet. The repo currently contains only `.claude/` and this file. Architecture is locked (see below); the next step is scaffolding `plugin/init.lua`.

## Platform constraint (verified via Context7)

WezTerm's plugin API exposes visual decoration only at **fixed singleton surfaces** (`update-status`, `set_right_status`, `format-tab-title`, `format-window-title`). There is **no API for drawing per-row content overlaid on the terminal grid** — iTerm2's column is part of iTerm2's native renderer.

Consequence: a pixel-exact copy is impossible without forking WezTerm itself. We approximate.

## Locked architecture

| Concern | Decision | Notes |
|---|---|---|
| **Display surface** | Sibling gutter pane (right side) | `SplitPane` creates a narrow right pane; plugin writes timestamps row-by-row into it. The pane border is the divider. Known limitation: independent scroll between panes — must be re-synced on every `update-status` tick. |
| **Time source** | Scrollback-diff polling | Each tick, snapshot `pane:get_logical_lines_as_text(scrollback_rows)`; lines not in prior snapshot are stamped with `os.time()`. Lossy when N lines land in one tick (all share one timestamp) — acceptable for v0. |
| **Toggle binding** | `Cmd+E` | `table.insert` into `config.keys` from `apply_to_config` — never reassign the table. |
| **Toggle scope** | **Global** (all windows) | Deliberate divergence from iTerm2's per-tab behavior — user choice. State is a single `wezterm.GLOBAL.line_time_enabled` boolean. On toggle, iterate windows/tabs and show/hide each gutter pane accordingly. |
| **State storage** | `wezterm.GLOBAL` | Survives config reloads; namespaced under `line_time.*` (`enabled`, `buffers[pane_id]`, `gutter_pane_ids[main_pane_id]`). |

## Implementation order (when greenlit)

1. `plugin/init.lua` returning `{ apply_to_config = function(config, opts) ... end }`.
2. Gutter pane lifecycle: open on Cmd+E if absent, close if present. Track parent↔gutter mapping in `wezterm.GLOBAL`.
3. `update-status` handler: for each main pane with a live gutter, diff scrollback, append new timestamps to per-pane ring buffer, push the visible window of timestamps into the gutter pane (writing via `pane:inject_output` or similar — verify exact API at implementation time, do not guess).
4. Resize / split / close handlers: keep mapping consistent, evict orphaned entries.
5. Manual smoke test in WezTerm with `wezterm.plugin.require 'file:///Users/yarnaid/projects/line_time'`.

## Known risks to revisit before merging v0

- **Scroll desync** between main and gutter panes — likely the dominant bug class. Confirm whether the gutter pane can be made non-scrollable / locked, or whether we have to forcibly re-snap its viewport every tick.
- **Performance**: polling full `scrollback_rows` per tick is O(scrollback) per pane. Cap snapshot size or hash-fingerprint per row to skip unchanged.
- **The "write into a pane" mechanism is not yet verified** — WezTerm panes are normally driven by their child process. Writing arbitrary text into a pane the plugin doesn't own may require running a tiny helper process in the gutter pane (e.g., `tail -f` on a FIFO the plugin writes to). Verify via Context7 / WezTerm source before committing to the design.

## WezTerm plugin conventions (verified via Context7)

- **Entry point**: `plugin/init.lua`. Consumers load via `wezterm.plugin.require '<git-url-or-file://path>'`. The returned table is the plugin's public API.
- **Local development**: load with the `file://` protocol — `wezterm.plugin.require 'file:///Users/yarnaid/projects/line_time'` from the user's `wezterm.lua`. Edits picked up on config reload.
- **Multiple modules**: the plugin itself must append its `plugin/` dir to `package.path` using `wezterm.plugin.list()` to locate `plugin_dir`. Don't rely on the consumer's path.
- **Public API discipline**: return one table from `plugin/init.lua` with named functions (`M.apply_to_config(config, opts)` is the WezTerm de-facto pattern). Internal helpers as `local`; visibility is by Lua scope, not by `__all__`.
- **No mutation of consumer state**: never assign to `config.keys = {...}`. Always `table.insert` or merge — the user may already have keys configured.

## Commands

None yet — no build, no test runner, no linter configured. When tooling is introduced, add it here:

- **Format/lint** (proposed, add when first churn appears): `stylua` + `luacheck` once a `.luacheckrc` / `stylua.toml` exists.
- **Test** (proposed): `busted` is the WezTerm-ecosystem norm; only add if logic justifies it.

Don't add tooling speculatively — wait until there's enough code that the absence is causing real friction.

## Open items before writing any code

1. **Resolve the platform constraint** with user: accept Option A (sibling gutter pane, best fidelity but scroll-sync caveats) or fall back to B (single right-status timestamp).
2. **Confirm timestamp source**: B1 (scrollback-diff polling, default) vs. B2 (shell integration, opt-in).
3. **Confirm Cmd+E scope**: per-tab (matches iTerm2) vs. per-window.
4. Only then: create `plugin/init.lua` returning `{ apply_to_config = function(config, opts) ... end }` and a `README.md` with the `wezterm.plugin.require` one-liner.
