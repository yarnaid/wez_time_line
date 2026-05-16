--[[
line_time — WezTerm plugin: per-line timestamp gutter on the right of each pane.

Enabled by default on first launch; Cmd+E toggles off/on (global — affects all
panes in all windows). State is persisted in wezterm.GLOBAL, so an explicit
toggle-off survives config reloads.

v0 limitations (see CLAUDE.md and README):
  * timestamp resolution = update-status tick (~1s); bursts share a stamp
  * unix-only: gutter child is `sleep`
  * `inject_output` does not work on multiplexer (remote) panes
  * mouse-wheel / scrollbar drag desync the gutter — WezTerm does not expose
    viewport scroll position or a scroll event to plugins. Only the keyboard
    scroll bindings we override (Shift+Up/Down/PageUp/PageDown) stay in sync.

Public API:
  M.apply_to_config(config, opts?)   register keybinding + tick handler
--]]

local wezterm = require 'wezterm'
local act = wezterm.action

local GUTTER_WIDTH = 10
local GUTTER_CMD = { 'sleep', '2147483647' }
local CLEAR_HOME = '\x1b[?25l\x1b[H\x1b[2J'
local CLOSE_PANE = wezterm.action.CloseCurrentPane { confirm = false }

-- DIAGNOSTIC: writes to /tmp/line_time.log unconditionally so we bypass any
-- ambiguity about where wezterm.log_warn ends up. `tail -F /tmp/line_time.log`
-- in another tab to watch live. Remove once we've identified the bug.
local DEBUG_LOG_PATH = '/tmp/line_time.log'
local function dlog(msg)
  local f = io.open(DEBUG_LOG_PATH, 'a')
  if f then
    f:write(os.date('%H:%M:%S ') .. msg .. '\n')
    f:close()
  end
end

-- wezterm.GLOBAL gotchas (verified empirically against 20240203):
--   1. `local t = wezterm.GLOBAL.X; t.Y = Z` does NOT propagate — reads return
--      a snapshot. Always mutate through `wezterm.GLOBAL.line_time.X` directly.
--   2. The store is JSON-like: nested-table keys must be strings. pane_id()
--      returns a number → stringify via k() before indexing.
-- Initialise each sub-table separately. wezterm.GLOBAL.line_time = {..., t={}}
-- in one assignment empirically loses the empty nested tables — they come
-- back as nil. Setting each field via wezterm.GLOBAL.line_time.X = {} works.
-- This also serves as a hot-reload backfill: if the plugin was updated via
-- wezterm.plugin.update_all() without a process restart, an older
-- line_time table (missing newer fields like viewport_top) is still in
-- wezterm.GLOBAL — fill in only the missing pieces.
-- viewport_top[pid] = row index of the topmost visible row in the main pane.
-- Absent/0 means "follow the live tail"; a positive number pins the gutter
-- to that row even as new content arrives below.
local function init_state()
  if wezterm.GLOBAL.line_time == nil then wezterm.GLOBAL.line_time = {} end
  if wezterm.GLOBAL.line_time.enabled == nil then wezterm.GLOBAL.line_time.enabled = true end
  if wezterm.GLOBAL.line_time.gutter == nil then wezterm.GLOBAL.line_time.gutter = {} end
  if wezterm.GLOBAL.line_time.stamps == nil then wezterm.GLOBAL.line_time.stamps = {} end
  if wezterm.GLOBAL.line_time.last_count == nil then wezterm.GLOBAL.line_time.last_count = {} end
  if wezterm.GLOBAL.line_time.viewport_top == nil then wezterm.GLOBAL.line_time.viewport_top = {} end
end

local function k(pane_id) return tostring(pane_id) end

local function is_gutter(pane_id)
  for _, gid in pairs(wezterm.GLOBAL.line_time.gutter) do
    if gid == pane_id then return true end
  end
  return false
end

local function count_lines(text)
  local n = 0
  for _ in text:gmatch '\n' do n = n + 1 end
  return n
end

local function live_tail_top(total, viewport)
  return math.max(1, total - viewport + 1)
end

local function clamp_top(top, total, viewport)
  if top < 1 then return 1 end
  local max_top = live_tail_top(total, viewport)
  if top > max_top then return max_top end
  return top
end

local function effective_top(id, total, viewport)
  local pinned = wezterm.GLOBAL.line_time.viewport_top[id] or 0
  if pinned == 0 then return live_tail_top(total, viewport) end
  return pinned
end

local function open_gutter(main_pane)
  local id = k(main_pane:pane_id())
  if wezterm.GLOBAL.line_time.gutter[id] then return end
  dlog('open_gutter: pane ' .. id)
  -- pane:split focuses the new pane. Remember the tab's active pane first so
  -- we can hand focus back — otherwise a lazy-open from update-status (or a
  -- toggle while a sibling is focused) yanks the cursor into the gutter.
  local tab = main_pane:tab()
  local prev_active = tab and tab:active_pane()
  local gutter = main_pane:split {
    direction = 'Right', size = GUTTER_WIDTH, args = GUTTER_CMD,
  }
  wezterm.GLOBAL.line_time.gutter[id] = gutter:pane_id()
  wezterm.GLOBAL.line_time.stamps[id] = {}
  wezterm.GLOBAL.line_time.last_count[id] = 0
  wezterm.GLOBAL.line_time.viewport_top[id] = 0
  if prev_active and prev_active:pane_id() ~= gutter:pane_id() then
    pcall(function() prev_active:activate() end)
  end
end

-- Close the gutter via the official CloseCurrentPane action — documented to
-- "shut down the PTY and kill the process", which bypasses exit_behavior.
-- We can't just `send_text '\x03'`: sleep exiting on SIGINT yields status
-- 130, and the default exit_behavior = "CloseOnCleanExit" holds the pane
-- open on non-zero exits, so the orphaned gutter would linger (full-width,
-- since its main sibling is gone) and block the tab from closing. The CLI
-- (wezterm cli kill-pane) was an earlier attempt — turned out to no-op in
-- practice from inside background_child_process. perform_action requires a
-- GUI window; derive it from the gutter pane itself so this works for any
-- window, regardless of which one's update-status fired.
local function close_gutter(main_id)
  local key = k(main_id)
  local gid = wezterm.GLOBAL.line_time.gutter[key]
  if not gid then return end
  local gpane = wezterm.mux.get_pane(gid)
  if gpane then
    local mux_win = gpane:window()
    local gui_win = mux_win and mux_win:gui_window()
    if gui_win then gui_win:perform_action(CLOSE_PANE, gpane) end
  end
  wezterm.GLOBAL.line_time.gutter[key] = nil
  wezterm.GLOBAL.line_time.stamps[key] = nil
  wezterm.GLOBAL.line_time.last_count[key] = nil
  wezterm.GLOBAL.line_time.viewport_top[key] = nil
end

local function record_new_lines(main_pane)
  local id = k(main_pane:pane_id())
  local dims = main_pane:get_dimensions()
  local text = main_pane:get_logical_lines_as_text(dims.scrollback_rows)
  local count = count_lines(text)
  local prev = wezterm.GLOBAL.line_time.last_count[id] or 0
  if count <= prev then return end
  local now = os.date '%H:%M:%S'
  for i = prev + 1, count do
    wezterm.GLOBAL.line_time.stamps[id][tostring(i)] = now
  end
  wezterm.GLOBAL.line_time.last_count[id] = count
end

local function render_gutter(main_pane, gutter_pane)
  local id = k(main_pane:pane_id())
  local total = wezterm.GLOBAL.line_time.last_count[id] or 0
  local viewport = main_pane:get_dimensions().viewport_rows
  local top = effective_top(id, total, viewport)
  local lines = {}
  for i = top, top + viewport - 1 do
    lines[#lines + 1] = wezterm.GLOBAL.line_time.stamps[id][tostring(i)] or ''
  end
  gutter_pane:inject_output(CLEAR_HOME .. table.concat(lines, '\r\n'))
end

-- pcall on the per-pane callback so a single failure (e.g. pane:split
-- raising for a freshly-spawned window before WezTerm finishes wiring up
-- its GUI surface) doesn't abort iteration over the rest of the panes.
-- Errors are written to ~/.local/share/wezterm/wezterm-gui.log on macOS;
-- see `wezterm show-log` for live tailing.
local function each_main_pane(fn)
  for _, mux_win in ipairs(wezterm.mux.all_windows()) do
    for _, tab in ipairs(mux_win:tabs()) do
      for _, pane in ipairs(tab:panes()) do
        if not is_gutter(pane:pane_id()) then
          local ok, err = pcall(fn, pane)
          if not ok then
            wezterm.log_error('line_time: pane ' .. tostring(pane:pane_id()) .. ' failed: ' .. tostring(err))
          end
        end
      end
    end
  end
end

local function instrument_all() each_main_pane(open_gutter) end

local function teardown_all()
  for main_id in pairs(wezterm.GLOBAL.line_time.gutter) do close_gutter(main_id) end
end

-- Sweep gutter mapping for entries whose main pane has died. Typical trigger:
-- user pressed Ctrl+D in the main pane, the shell exited, WezTerm dropped the
-- pane — but the sibling gutter (running `sleep`) is still alive, so the tab
-- survives with only timestamps on screen. Reaping the orphan lets the tab/
-- window close in turn. Worst-case latency = one update-status tick (~1s).
-- Also self-heals stale entries left over from config reloads or earlier
-- crashes, since wezterm.GLOBAL outlives the Lua VM.
local function reap_orphan_gutters()
  local dead = {}
  for main_key in pairs(wezterm.GLOBAL.line_time.gutter) do
    local pid = tonumber(main_key)
    if not pid or not wezterm.mux.get_pane(pid) then
      dead[#dead + 1] = main_key
    end
  end
  for _, key in ipairs(dead) do close_gutter(key) end
end

-- Lazy-opens the gutter for any main pane that doesn't have one yet. This is
-- how the plugin becomes visible on a fresh process (enabled=true by default
-- but apply_to_config runs before mux has any windows — only update-status
-- sees real panes) and how panes spawned later acquire a gutter without a
-- toggle off/on dance. A stale gid (user closed the gutter pane manually) is
-- left alone — open_gutter is no-op when gid is present, regardless of
-- whether the underlying mux pane is still alive.
local function tick()
  if not wezterm.GLOBAL.line_time then
    dlog('tick: no state')
    return
  end
  if not wezterm.GLOBAL.line_time.enabled then
    dlog('tick: disabled')
    return
  end
  local window_count = #wezterm.mux.all_windows()
  dlog('tick: enabled, windows=' .. window_count)
  reap_orphan_gutters()
  local seen = 0
  each_main_pane(function(pane)
    seen = seen + 1
    local id = k(pane:pane_id())
    dlog('tick: main pane ' .. id .. ' has_gutter=' .. tostring(wezterm.GLOBAL.line_time.gutter[id] ~= nil))
    if not wezterm.GLOBAL.line_time.gutter[id] then
      open_gutter(pane)
      return
    end
    local gpane = wezterm.mux.get_pane(wezterm.GLOBAL.line_time.gutter[id])
    if not gpane then return end
    record_new_lines(pane)
    render_gutter(pane, gpane)
  end)
  dlog('tick: saw ' .. seen .. ' main panes')
end

local function toggle()
  init_state()
  wezterm.GLOBAL.line_time.enabled = not wezterm.GLOBAL.line_time.enabled
  dlog('toggle: enabled=' .. tostring(wezterm.GLOBAL.line_time.enabled))
  if wezterm.GLOBAL.line_time.enabled then instrument_all() else teardown_all() end
end

-- Wraps a scroll action so the gutter's viewport_top tracks the main pane's
-- visual scroll. delta_fn is called at fire time with the active pane so
-- page-size deltas can read the current (possibly resized) viewport_rows.
-- The real scroll is still performed via window:perform_action, and the
-- gutter is re-rendered immediately (don't wait for the next tick).
local function on_scroll(delta_fn)
  return wezterm.action_callback(function(window, pane)
    local viewport = pane:get_dimensions().viewport_rows
    local delta = delta_fn(viewport)
    window:perform_action(act.ScrollByLine(delta), pane)
    if not wezterm.GLOBAL.line_time or not wezterm.GLOBAL.line_time.enabled then return end
    if is_gutter(pane:pane_id()) then return end
    local id = k(pane:pane_id())
    local gid = wezterm.GLOBAL.line_time.gutter[id]
    if not gid then return end
    local total = wezterm.GLOBAL.line_time.last_count[id] or 0
    local cur = effective_top(id, total, viewport)
    local new_top = clamp_top(cur + delta, total, viewport)
    if new_top == live_tail_top(total, viewport) then
      wezterm.GLOBAL.line_time.viewport_top[id] = 0
    else
      wezterm.GLOBAL.line_time.viewport_top[id] = new_top
    end
    local gpane = wezterm.mux.get_pane(gid)
    if gpane then render_gutter(pane, gpane) end
  end)
end

local M = {}

---@param config table   wezterm config table being built
---@param opts? table    reserved for future options
function M.apply_to_config(config, opts)
  dlog('apply_to_config: entered')
  init_state()
  dlog('apply_to_config: state initialised, enabled=' .. tostring(wezterm.GLOBAL.line_time.enabled))
  config.keys = config.keys or {}
  table.insert(config.keys, {
    key = 'e', mods = 'CMD', action = wezterm.action_callback(toggle),
  })
  -- Override the default scroll bindings so we can track viewport_top. The
  -- real scroll still happens via window:perform_action inside on_scroll;
  -- when the plugin is disabled, the wrappers degrade to plain scrolls.
  local one_up    = function() return -1 end
  local one_down  = function() return 1 end
  local page_up   = function(vp) return -vp end
  local page_down = function(vp) return vp end
  table.insert(config.keys, { key = 'UpArrow',   mods = 'SHIFT', action = on_scroll(one_up) })
  table.insert(config.keys, { key = 'DownArrow', mods = 'SHIFT', action = on_scroll(one_down) })
  table.insert(config.keys, { key = 'PageUp',    mods = 'SHIFT', action = on_scroll(page_up) })
  table.insert(config.keys, { key = 'PageDown',  mods = 'SHIFT', action = on_scroll(page_down) })
  -- wezterm.on is per-Lua-VM. Each config reload (including validation
  -- threads) gets a fresh VM with no prior handlers — register every time.
  wezterm.on('update-status', tick)
  dlog('apply_to_config: update-status handler registered')
end

return M
