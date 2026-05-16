--[[
line_time — WezTerm plugin: per-line timestamp gutter on the right of each pane.

Toggle: Cmd+E (global; affects all panes in all windows).

v0 limitations (see CLAUDE.md):
  * panes opened while enabled get no gutter until toggle off/on
  * timestamp resolution = update-status tick (~1s); bursts share a stamp
  * unix-only: gutter child is `sleep`
  * `inject_output` does not work on multiplexer (remote) panes

Public API:
  M.apply_to_config(config, opts?)   register keybinding + tick handler
--]]

local wezterm = require 'wezterm'

local GUTTER_WIDTH = 10
local GUTTER_CMD = { 'sleep', '2147483647' }
local CLEAR_HOME = '\x1b[?25l\x1b[H\x1b[2J'

-- DIAG: temporary diagnostics. log_error is always written to the gui log.
local function dbg(...)
  local parts = { '[line_time]' }
  for i = 1, select('#', ...) do parts[#parts + 1] = tostring(select(i, ...)) end
  wezterm.log_error(table.concat(parts, ' '))
end

-- wezterm.GLOBAL.X reads return a *snapshot* of the underlying table — writes
-- to a cached local do NOT propagate. So we never cache; every mutation goes
-- through wezterm.GLOBAL.line_time directly, which IS proxied for writes
-- (since wezterm 20230320-124340).
-- Also: wezterm.GLOBAL is JSON-like, so nested-table keys must be strings.
-- pane_id() returns a number → always stringify before indexing.
local function init_state()
  if wezterm.GLOBAL.line_time == nil then
    wezterm.GLOBAL.line_time = {
      enabled = false, gutter = {}, stamps = {}, last_count = {},
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

local function open_gutter(main_pane)
  local id = k(main_pane:pane_id())
  dbg('open_gutter pane=', id)
  if wezterm.GLOBAL.line_time.gutter[id] then
    dbg('open_gutter pane=', id, 'already has gutter, skip')
    return
  end
  local ok, gutter_or_err = pcall(function()
    return main_pane:split {
      direction = 'Right', size = GUTTER_WIDTH, args = GUTTER_CMD,
    }
  end)
  if not ok then
    dbg('open_gutter pane=', id, 'SPLIT FAILED:', gutter_or_err)
    return
  end
  if not gutter_or_err then
    dbg('open_gutter pane=', id, 'SPLIT returned nil')
    return
  end
  local gid = gutter_or_err:pane_id()
  dbg('open_gutter pane=', id, 'split ok, gutter_pane=', gid)
  wezterm.GLOBAL.line_time.gutter[id] = gid
  wezterm.GLOBAL.line_time.stamps[id] = {}
  wezterm.GLOBAL.line_time.last_count[id] = 0
end

local function close_gutter(main_id)
  -- main_id may arrive as number (from is_gutter caller) or string (from
  -- pairs() iteration over GLOBAL table). Normalise.
  local key = k(main_id)
  local gid = wezterm.GLOBAL.line_time.gutter[key]
  dbg('close_gutter main_id=', key, 'gutter_id=', gid)
  if not gid then return end
  local gpane = wezterm.mux.get_pane(gid)
  if gpane then
    local ok, err = pcall(function() gpane:send_text '\x03' end)
    if not ok then dbg('close_gutter send_text failed:', err) end
  else
    dbg('close_gutter: gutter pane', gid, 'not found in mux')
  end
  wezterm.GLOBAL.line_time.gutter[key] = nil
  wezterm.GLOBAL.line_time.stamps[key] = nil
  wezterm.GLOBAL.line_time.last_count[key] = nil
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
  local first = math.max(1, total - viewport + 1)
  local lines = {}
  for i = first, total do
    lines[#lines + 1] = wezterm.GLOBAL.line_time.stamps[id][tostring(i)] or ''
  end
  gutter_pane:inject_output(CLEAR_HOME .. table.concat(lines, '\r\n'))
end

local function each_main_pane(fn)
  local nwin = 0
  local npanes = 0
  for _, mux_win in ipairs(wezterm.mux.all_windows()) do
    nwin = nwin + 1
    for _, tab in ipairs(mux_win:tabs()) do
      for _, pane in ipairs(tab:panes()) do
        if not is_gutter(pane:pane_id()) then
          npanes = npanes + 1
          fn(pane)
        end
      end
    end
  end
  dbg('each_main_pane visited windows=', nwin, 'main_panes=', npanes)
end

local function instrument_all()
  dbg('instrument_all')
  each_main_pane(open_gutter)
end

local function teardown_all()
  dbg('teardown_all')
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
  local before = wezterm.GLOBAL.line_time.enabled
  wezterm.GLOBAL.line_time.enabled = not before
  local after = wezterm.GLOBAL.line_time.enabled
  dbg('toggle before=', before, 'after=', after)
  local ok, err
  if after then
    ok, err = pcall(instrument_all)
  else
    ok, err = pcall(teardown_all)
  end
  if not ok then dbg('toggle FAILED:', err) end
end

local M = {}

---@param config table   wezterm config table being built
---@param opts? table    reserved for future options
function M.apply_to_config(config, opts)
  dbg('apply_to_config called')
  init_state()
  config.keys = config.keys or {}
  -- Idempotent: each config reload re-runs apply_to_config (sometimes many
  -- times per reload across validation threads). Avoid stacking duplicate
  -- Cmd+E entries inside the same config.keys list.
  local bound = false
  for _, entry in ipairs(config.keys) do
    if entry.key == 'e' and entry.mods == 'CMD' then bound = true break end
  end
  if not bound then
    table.insert(config.keys, {
      key = 'e', mods = 'CMD', action = wezterm.action_callback(toggle),
    })
  end
  -- wezterm.on accumulates handlers across reloads; guard with a GLOBAL flag.
  if not wezterm.GLOBAL.line_time_hooked then
    wezterm.GLOBAL.line_time_hooked = true
    wezterm.on('update-status', tick)
  end
end

return M
