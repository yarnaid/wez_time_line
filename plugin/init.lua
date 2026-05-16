--[[
line_time — WezTerm plugin: per-line timestamp gutter on the right of each pane.

Toggle: Cmd+E (global; affects all panes in all windows).

v0 limitations (see CLAUDE.md and README):
  * panes opened while enabled get no gutter until toggle off/on
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

-- wezterm.GLOBAL gotchas (verified empirically against 20240203):
--   1. `local t = wezterm.GLOBAL.X; t.Y = Z` does NOT propagate — reads return
--      a snapshot. Always mutate through `wezterm.GLOBAL.line_time.X` directly.
--   2. The store is JSON-like: nested-table keys must be strings. pane_id()
--      returns a number → stringify via k() before indexing.
local function init_state()
  if wezterm.GLOBAL.line_time == nil then
    wezterm.GLOBAL.line_time = {
      enabled = false,
      gutter = {},
      stamps = {},
      last_count = {},
      -- viewport_top[pid] = row index of the topmost visible row in the main
      -- pane. Absent/0 means "follow the live tail"; a positive number pins
      -- the gutter to that row even as new content arrives below.
      viewport_top = {},
    }
  end
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
  local gutter = main_pane:split {
    direction = 'Right', size = GUTTER_WIDTH, args = GUTTER_CMD,
  }
  wezterm.GLOBAL.line_time.gutter[id] = gutter:pane_id()
  wezterm.GLOBAL.line_time.stamps[id] = {}
  wezterm.GLOBAL.line_time.last_count[id] = 0
  wezterm.GLOBAL.line_time.viewport_top[id] = 0
end

local function close_gutter(main_id)
  local key = k(main_id)
  local gid = wezterm.GLOBAL.line_time.gutter[key]
  if not gid then return end
  local gpane = wezterm.mux.get_pane(gid)
  if gpane then gpane:send_text '\x03' end
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

local function each_main_pane(fn)
  for _, mux_win in ipairs(wezterm.mux.all_windows()) do
    for _, tab in ipairs(mux_win:tabs()) do
      for _, pane in ipairs(tab:panes()) do
        if not is_gutter(pane:pane_id()) then fn(pane) end
      end
    end
  end
end

local function instrument_all() each_main_pane(open_gutter) end

local function teardown_all()
  for main_id in pairs(wezterm.GLOBAL.line_time.gutter) do close_gutter(main_id) end
end

local function tick()
  if not wezterm.GLOBAL.line_time then return end
  if not wezterm.GLOBAL.line_time.enabled then return end
  each_main_pane(function(pane)
    local gid = wezterm.GLOBAL.line_time.gutter[k(pane:pane_id())]
    local gpane = gid and wezterm.mux.get_pane(gid)
    if not gpane then return end
    record_new_lines(pane)
    render_gutter(pane, gpane)
  end)
end

local function toggle()
  init_state()
  wezterm.GLOBAL.line_time.enabled = not wezterm.GLOBAL.line_time.enabled
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
  init_state()
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
end

return M
