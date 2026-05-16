--[[
line_time — WezTerm plugin: per-line timestamp gutter on the right of each pane.

Enabled by default; Cmd+E toggles off/on (global — affects all panes in all
windows). Toggle state lives in a Lua VM local (NOT wezterm.GLOBAL — see the
`enabled` comment below), so a fresh GUI process always defaults to on.

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

-- After splitting we mark the new pane with this user var via OSC 1337 so we
-- can re-discover existing gutter panes across config reloads / VM restarts
-- without depending on any in-memory mapping. Value is base64("1") = "MQ==".
local GUTTER_USER_VAR = 'line_time_gutter'
local MARK_GUTTER_OSC = '\x1b]1337;SetUserVar=' .. GUTTER_USER_VAR .. '=MQ==\x07'

-- All mutable state lives as module locals, NOT in wezterm.GLOBAL.
--
-- wezterm.GLOBAL turned out to be a footgun: it wraps stored values in an
-- opaque "Value" userdata on read-back (tostring gives "Value: 0x..." with no
-- way to recover the underlying pane id), so id comparisons silently
-- mis-fired: every freshly-created gutter was misclassified as a new main
-- pane on the next tick, splitting it again → infinite cascade of nested
-- gutter panes. Plain Lua tables sidestep the entire mess.
--
-- Cost: state doesn't survive config reload. The `reclaim_existing_gutter`
-- pass on each tick rebuilds the mapping by scanning panes for the
-- GUTTER_USER_VAR marker, so a reload doesn't strand existing gutters — they
-- get re-adopted by their sibling main pane within one tick.
local enabled = true
local gutters = {}        -- [main_id (number)] = gutter_id (number)
local stamps = {}         -- [main_id] = { [row_index_str] = "HH:MM:SS" }
local last_count = {}     -- [main_id] = number of logical lines seen so far
local viewport_top = {}   -- [main_id] = pinned top row (0 = follow live tail)
-- Tracks whether we've ever observed a foreground process in the main pane.
-- Used to distinguish "shell still booting, no process yet" (don't reap) from
-- "shell exited but exit_behavior=Hold is keeping the pane around" (do reap).
local proc_seen = {}      -- [main_id] = true once we've seen any fg process

-- wezterm.mux.get_pane(id) THROWS a Lua error when the pane id is unknown,
-- contrary to what one would expect from "get" semantics. Wrap it: a missing
-- pane is a normal flow ("did this pane die yet?") and must not abort the
-- reaper or any other caller. Without this wrapper every Ctrl+D path threw
-- silently inside the event handler.
local function safe_get_pane(id)
  if not id then return nil end
  local ok, pane = pcall(wezterm.mux.get_pane, id)
  if not ok then return nil end
  return pane
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
  local pinned = viewport_top[id] or 0
  if pinned == 0 then return live_tail_top(total, viewport) end
  return pinned
end

-- A pane is a gutter if either:
--   1. Its user vars contain our marker (set by inject of MARK_GUTTER_OSC
--      after we split it). This is the primary identity.
--   2. Its foreground process is `sleep 2147483647`. Fallback for panes
--      created before the user var marker was added (recovers stragglers
--      from buggy older sessions).
local function is_gutter(pane)
  local vars = pane:get_user_vars()
  if vars and vars[GUTTER_USER_VAR] == '1' then return true end
  local proc = pane:get_foreground_process_info()
  if proc and proc.argv and proc.argv[1]
    and proc.argv[1]:match 'sleep$'
    and proc.argv[2] == '2147483647'
  then
    return true
  end
  return false
end

-- For a given main pane, look at its tab's other panes and return the first
-- that's a gutter. Used to reclaim gutter ownership across VM restarts and
-- to avoid double-splitting if state was lost but the gutter pane survived.
local function find_sibling_gutter(main_pane)
  local tab = main_pane:tab()
  if not tab then return nil end
  local main_id = main_pane:pane_id()
  for _, pane in ipairs(tab:panes()) do
    if pane:pane_id() ~= main_id and is_gutter(pane) then return pane end
  end
  return nil
end

local function set_stub_state(main_id)
  stamps[main_id] = stamps[main_id] or {}
  last_count[main_id] = last_count[main_id] or 0
  viewport_top[main_id] = viewport_top[main_id] or 0
end

local function clear_state(main_id)
  gutters[main_id] = nil
  stamps[main_id] = nil
  last_count[main_id] = nil
  viewport_top[main_id] = nil
  proc_seen[main_id] = nil
end

local function open_gutter(main_pane)
  local id = main_pane:pane_id()
  if gutters[id] then return end
  -- Re-claim across reloads: if a sibling pane is already a gutter (left over
  -- from before the VM restart), adopt it instead of spawning a new one.
  local existing = find_sibling_gutter(main_pane)
  if existing then
    gutters[id] = existing:pane_id()
    set_stub_state(id)
    return
  end
  -- pane:split focuses the new pane. Remember the tab's active pane first so
  -- we can hand focus back — otherwise a lazy-open from update-status yanks
  -- the cursor into the gutter.
  local tab = main_pane:tab()
  local prev_active = tab and tab:active_pane()
  local gutter = main_pane:split {
    direction = 'Right', size = GUTTER_WIDTH, args = GUTTER_CMD,
  }
  -- Mark the new pane as ours so future ticks (and future VMs after reload)
  -- can identify it without consulting any external mapping.
  gutter:inject_output(MARK_GUTTER_OSC)
  gutters[id] = gutter:pane_id()
  set_stub_state(id)
  if prev_active and prev_active:pane_id() ~= gutter:pane_id() then
    pcall(function() prev_active:activate() end)
  end
end

-- Close the gutter both ways: CloseCurrentPane action via the gui window,
-- AND `wezterm cli kill-pane` in the background. Either should be sufficient
-- in isolation, but in practice one or the other has silently no-op'd
-- depending on the surrounding state — empirically gui_window() returns nil
-- for orphan gutter panes whose sibling main has just died, so perform_action
-- never reaches the close path. The CLI doesn't care about gui state; it
-- talks straight to the mux server. Firing both is idempotent and self-heals.
local WEZTERM_BIN = wezterm.executable_dir .. '/wezterm'
local function kill_pane(gpane)
  if not gpane then return end
  local pid = gpane:pane_id()
  local mux_win = gpane:window()
  local gui_win = mux_win and mux_win:gui_window()
  if gui_win then
    pcall(function() gui_win:perform_action(CLOSE_PANE, gpane) end)
  end
  pcall(function()
    wezterm.background_child_process {
      WEZTERM_BIN, 'cli', 'kill-pane', '--pane-id', tostring(pid),
    }
  end)
end

local function close_gutter(main_id)
  local gid = gutters[main_id]
  if not gid then return end
  kill_pane(safe_get_pane(gid))
  clear_state(main_id)
end

local function record_new_lines(main_pane)
  local id = main_pane:pane_id()
  local dims = main_pane:get_dimensions()
  local text = main_pane:get_logical_lines_as_text(dims.scrollback_rows)
  local count = count_lines(text)
  local prev = last_count[id] or 0
  if count <= prev then return end
  local now = os.date '%H:%M:%S'
  for i = prev + 1, count do
    stamps[id][tostring(i)] = now
  end
  last_count[id] = count
end

local function render_gutter(main_pane, gutter_pane)
  local id = main_pane:pane_id()
  local total = last_count[id] or 0
  local viewport = main_pane:get_dimensions().viewport_rows
  local top = effective_top(id, total, viewport)
  local lines = {}
  local stamp_table = stamps[id] or {}
  for i = top, top + viewport - 1 do
    lines[#lines + 1] = stamp_table[tostring(i)] or ''
  end
  gutter_pane:inject_output(CLEAR_HOME .. table.concat(lines, '\r\n'))
end

-- pcall on the per-pane callback so a single failure (e.g. pane:split
-- raising for a freshly-spawned window before WezTerm finishes wiring up
-- its GUI surface) doesn't abort iteration over the rest of the panes.
local function each_main_pane(fn)
  for _, mux_win in ipairs(wezterm.mux.all_windows()) do
    for _, tab in ipairs(mux_win:tabs()) do
      for _, pane in ipairs(tab:panes()) do
        if not is_gutter(pane) then pcall(fn, pane) end
      end
    end
  end
end

local function instrument_all() each_main_pane(open_gutter) end

local function teardown_all()
  for main_id in pairs(gutters) do close_gutter(main_id) end
end

-- Sweep mapping for entries whose main pane has died. Two cases:
--   1. mux.get_pane(main_id) returns nil — pane was removed from the mux
--      (default exit_behavior closes the pane on shell exit).
--   2. main pane is still in mux but `get_foreground_process_info()` returns
--      nil after we've previously seen a process there — shell exited and
--      exit_behavior = "Hold" / "CloseOnCleanExit" is keeping the pane in a
--      "process gone" state. User pressed Ctrl+D expecting close; honour that.
-- For case 2 we also force-kill the held main pane via kill_pane, since
-- otherwise the tab survives with a zombie [Process exited] view.
local function reap_orphan_gutters()
  local to_kill = {}
  for main_id in pairs(gutters) do
    local mp = safe_get_pane(main_id)
    if not mp then
      to_kill[#to_kill + 1] = { main_id = main_id, mp = nil }
    else
      local proc = mp:get_foreground_process_info()
      if proc then
        proc_seen[main_id] = true
      elseif proc_seen[main_id] then
        to_kill[#to_kill + 1] = { main_id = main_id, mp = mp }
      end
    end
  end
  for _, item in ipairs(to_kill) do
    close_gutter(item.main_id)
    if item.mp then kill_pane(item.mp) end
  end
end

-- Find gutter panes that aren't claimed by any main in our mapping (e.g.
-- left over from a previous session whose main panes died before this VM
-- started). Kill them so they don't ghost-occupy tabs.
local function reap_unclaimed_gutters()
  -- Build set of claimed gutter pane ids.
  local claimed = {}
  for _, gid in pairs(gutters) do claimed[gid] = true end
  for _, mux_win in ipairs(wezterm.mux.all_windows()) do
    for _, tab in ipairs(mux_win:tabs()) do
      local panes = tab:panes()
      -- Only consider gutters orphaned if their tab has no main pane. A
      -- tab with main + gutter but no mapping entry is fine — open_gutter's
      -- reclaim path will adopt the gutter on the next tick. Kill only when
      -- there's literally nothing else in the tab.
      local has_main = false
      for _, pane in ipairs(panes) do
        if not is_gutter(pane) then has_main = true; break end
      end
      if not has_main then
        for _, pane in ipairs(panes) do
          if is_gutter(pane) and not claimed[pane:pane_id()] then kill_pane(pane) end
        end
      end
    end
  end
end

local function tick()
  if not enabled then return end
  pcall(reap_orphan_gutters)
  pcall(reap_unclaimed_gutters)
  each_main_pane(function(pane)
    local id = pane:pane_id()
    if not gutters[id] then
      open_gutter(pane)
      return
    end
    local gpane = safe_get_pane(gutters[id])
    if not gpane then
      -- Mapping points at a dead gutter — drop it so open_gutter tries again
      -- (or reclaims a sibling that's still alive) next tick.
      clear_state(id)
      return
    end
    record_new_lines(pane)
    render_gutter(pane, gpane)
  end)
end

local function toggle()
  enabled = not enabled
  if enabled then instrument_all() else teardown_all() end
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
    if not enabled then return end
    if is_gutter(pane) then return end
    local id = pane:pane_id()
    local gid = gutters[id]
    if not gid then return end
    local total = last_count[id] or 0
    local cur = effective_top(id, total, viewport)
    local new_top = clamp_top(cur + delta, total, viewport)
    if new_top == live_tail_top(total, viewport) then
      viewport_top[id] = 0
    else
      viewport_top[id] = new_top
    end
    local gpane = safe_get_pane(gid)
    if gpane then render_gutter(pane, gpane) end
  end)
end

local M = {}

---@param config table   wezterm config table being built
---@param opts? table    reserved for future options
function M.apply_to_config(config, opts)
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
