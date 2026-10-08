-- A small full-screen text UI toolkit for the OC2 terminal (80x24, 16 colours, DEC line drawing, mouse).
-- Used by the setup wizard, the swarm topology view and the desktop.
--
--   local T = require("shulker.tui")
--   T.start()                          raw keys + mouse reporting + hidden cursor (T.stop() undoes it)
--   T.clear(); T.at(x, y, text, fg, bg); T.box(x, y, w, h, title); T.flush()
--   local id = T.button(x, y, label, "key") ... then T.event() -> { type = "key"|"click"|"button", ... }
--   T.input(x, y, w, default, hidden) -> text | nil (Esc)
local U = require("shulker.util")

local M = { W = 80, H = 24 }
local ESC = "\27"
local G, A = ESC .. "(0", ESC .. "(B"

local COL = { black = 30, red = 31, green = 32, yellow = 33, blue = 34, purple = 35, cyan = 36, white = 37,
              gray = 90, pink = 91, lime = 92, gold = 93, sky = 94, lavender = 95, aqua = 96, bright = 97 }
M.COL = COL

local out = {}
local buttons = {}

local function emit(s) out[#out + 1] = s end
function M.flush()
  io.write(table.concat(out))
  io.flush()
  out = {}
end

local function color(fg, bg)
  local codes = { "0" }
  if fg then codes[#codes + 1] = tostring(COL[fg] or fg) end
  if bg then codes[#codes + 1] = tostring((COL[bg] or bg) + 10) end
  return ESC .. "[" .. table.concat(codes, ";") .. "m"
end

function M.size()
  local s = U.capture("stty size 2>/dev/null")
  local h, w = s:match("(%d+)%s+(%d+)")
  M.W, M.H = tonumber(w) or 80, tonumber(h) or 24
  if M.W < 40 then M.W = 80 end
  if M.H < 12 then M.H = 24 end
  return M.W, M.H
end

function M.start()
  M.size()
  os.execute("stty -icanon -echo min 1 2>/dev/null")
  -- hide cursor, mouse button reporting (1000) in SGR form (1006)
  io.write(ESC .. "[?25l" .. ESC .. "[?1000h" .. ESC .. "[?1006h")
  io.flush()
  M.active = true
end

function M.stop()
  if not M.active then return end
  io.write(ESC .. "[?1000l" .. ESC .. "[?1006l" .. ESC .. "[0m" .. ESC .. "[?25h" .. ESC .. "[2J" .. ESC .. "[H")
  io.flush()
  os.execute("stty sane 2>/dev/null")
  M.active = false
end

function M.clear(bg)
  buttons = {}
  emit(color(nil, bg) .. ESC .. "[2J" .. ESC .. "[H")
end

-- text at column x, row y (1-based); clipped to the screen width
function M.at(x, y, text, fg, bg)
  text = tostring(text)
  if y < 1 or y > M.H or x > M.W then return end
  if x < 1 then text = text:sub(2 - x) x = 1 end
  text = text:sub(1, M.W - x + 1)
  emit(ESC .. "[" .. y .. ";" .. x .. "H" .. color(fg, bg) .. text .. color())
end

-- DEC line drawing: chars in "lqkxmjtuwvn`a" become box pieces
function M.g(x, y, text, fg, bg)
  if y < 1 or y > M.H then return end
  emit(ESC .. "[" .. y .. ";" .. x .. "H" .. color(fg, bg) .. G .. text .. A .. color())
end

function M.fill(x, y, w, h, bg)
  for row = y, y + h - 1 do M.at(x, row, string.rep(" ", w), nil, bg) end
end

function M.box(x, y, w, h, title, fg)
  fg = fg or "purple"
  M.g(x, y, "l" .. string.rep("q", w - 2) .. "k", fg)
  for row = y + 1, y + h - 2 do
    M.g(x, row, "x", fg)
    M.g(x + w - 1, row, "x", fg)
  end
  M.g(x, y + h - 1, "m" .. string.rep("q", w - 2) .. "j", fg)
  if title then M.at(x + 2, y, " " .. title .. " ", "bright") end
end

function M.hline(x, y, w, fg) M.g(x, y, string.rep("q", w), fg or "purple") end

-- the shulker logo (6 lines, 11 wide)
function M.logo(x, y)
  M.g(x, y, "lqqqqqqqqqk", "purple")
  M.g(x, y + 1, "x", "purple") M.g(x + 1, y + 1, "aaaaaaaaa", "lavender") M.g(x + 10, y + 1, "x", "purple")
  M.g(x, y + 2, "tqqqqqqqqqu", "purple")
  M.g(x, y + 3, "x", "purple") M.g(x + 3, y + 3, "`   `", "bright") M.g(x + 10, y + 3, "x", "purple")
  M.g(x, y + 4, "x", "purple") M.at(x + 5, y + 4, "-", "lavender") M.g(x + 10, y + 4, "x", "purple")
  M.g(x, y + 5, "mqqqqqqqqqj", "purple")
end

-- word wrap
function M.wrap(text, width)
  local lines = {}
  for para in (tostring(text) .. "\n"):gmatch("(.-)\n") do
    if para == "" then lines[#lines + 1] = "" else
      local indent = para:match("^%s*")
      local line = indent
      for word in para:gmatch("%S+") do
        if #line + #word + 1 > width and line:match("%S") then
          lines[#lines + 1] = line
          line = indent .. word
        else
          line = (line:match("%S") and (line .. " ") or line) .. word
        end
      end
      lines[#lines + 1] = line
    end
  end
  return lines
end

function M.text(x, y, w, text, fg)
  for _, l in ipairs(M.wrap(text, w)) do M.at(x, y, l, fg) y = y + 1 end
  return y
end

-- a clickable button; key: the keyboard shortcut that does the same
function M.button(x, y, label, key, style)
  local fg, bg = "bright", "purple"
  if style == "quiet" then fg, bg = "bright", "gray" elseif style == "danger" then fg, bg = "bright", "red" end
  local text = " " .. label .. " "
  M.at(x, y, text, fg, bg)
  buttons[#buttons + 1] = { x = x, y = y, w = #text, key = key, label = label }
  return x + #text + 1
end

-- read one input event: { type = "key", key = "enter"|"up"|...|"a" } or { type = "click", x, y, button }
-- a click on a button (or its key) gives { type = "button", key = ... }
-- raw unbuffered reads (stdio buffering would hide bytes from poll); a lone Esc is told apart from
-- an escape sequence by waiting briefly for the next byte
local okP, P = pcall(function() return { unistd = require("posix.unistd"), poll = require("posix.poll") } end)
local pending = ""
local function readByte(wait)
  if #pending > 0 then local c = pending:sub(1, 1) pending = pending:sub(2) return c end
  if not okP then return io.read(1) end
  if wait then
    local n = P.poll.rpoll(0, wait)
    if not n or n == 0 then return nil end
  end
  local s = P.unistd.read(0, 64)
  if not s or s == "" then return nil end
  pending = s:sub(2)
  return s:sub(1, 1)
end

-- timeout (ms): return { type = "tick" } when nothing arrives in time (for live views)
function M.event(timeout)
  local ch = readByte(timeout)
  if ch == nil then return { type = timeout and "tick" or "eof" } end
  local ev
  if ch == ESC then
    local c2 = readByte(80)
    if c2 == "[" then
      local seq = ""
      while true do
        local c = readByte(200)
        if not c then break end
        seq = seq .. c
        if c:match("[%a~]") then break end
      end
      local b, cx, cy, kind = seq:match("^<(%d+);(%d+);(%d+)([Mm])$")
      if b then
        if kind == "m" then return M.event() end            -- release: wait for the next event
        ev = { type = "click", button = tonumber(b), x = tonumber(cx), y = tonumber(cy) }
      else
        local names = { A = "up", B = "down", C = "right", D = "left", H = "home", F = "end",
                        ["5~"] = "pgup", ["6~"] = "pgdn", ["3~"] = "delete", Z = "backtab" }
        ev = { type = "key", key = names[seq] or ("esc[" .. seq) }
      end
    elseif c2 == "O" then
      local c = readByte(200)
      ev = { type = "key", key = ({ A = "up", B = "down", C = "right", D = "left", H = "home", F = "end" })[c] or "esc" }
    else
      ev = { type = "key", key = "esc" }
    end
  elseif ch == "\r" or ch == "\n" then ev = { type = "key", key = "enter" }
  elseif ch == "\t" then ev = { type = "key", key = "tab" }
  elseif ch == "\127" or ch == "\8" then ev = { type = "key", key = "backspace" }
  elseif ch == "\3" then ev = { type = "key", key = "ctrl-c" }
  else ev = { type = "key", key = ch } end

  if ev.type == "click" then
    for _, b in ipairs(buttons) do
      if ev.y == b.y and ev.x >= b.x and ev.x < b.x + b.w then return { type = "button", key = b.key, label = b.label } end
    end
  elseif ev.type == "key" then
    for _, b in ipairs(buttons) do
      if b.key and ev.key == b.key then return { type = "button", key = b.key, label = b.label } end
    end
  end
  return ev
end

-- forget the buttons drawn so far (before a text field: typed letters must not trigger them)
function M.clearButtons() buttons = {} end

-- a one-line text field; returns the text, or nil on Esc
function M.input(x, y, w, default, hidden)
  local s = default or ""
  io.write(ESC .. "[?25h")
  while true do
    local shown = hidden and string.rep("*", #s) or s
    if #shown > w - 1 then shown = shown:sub(-(w - 1)) end
    M.at(x, y, shown .. string.rep(" ", w - #shown), "bright", "gray")
    emit(ESC .. "[" .. y .. ";" .. (x + #shown) .. "H")
    M.flush()
    local ev = M.event()
    if ev.type == "key" then
      if ev.key == "enter" then io.write(ESC .. "[?25l") return s end
      if ev.key == "esc" or ev.key == "ctrl-c" then io.write(ESC .. "[?25l") return nil end
      if ev.key == "backspace" then s = s:sub(1, -2)
      elseif #ev.key == 1 and ev.key:byte() >= 32 then s = s .. ev.key end
    elseif ev.type == "button" then
      io.write(ESC .. "[?25l")
      return s, ev
    end
  end
end

-- a choice list; items = { { label =, help = } }; returns the index or nil (Esc)
function M.choose(x, y, w, items, selected, onDraw)
  selected = selected or 1
  while true do
    for i, it in ipairs(items) do
      local mark = i == selected and "(*) " or "( ) "
      local fg = i == selected and "bright" or "white"
      local bg = i == selected and "purple" or nil
      M.at(x, y + (i - 1) * 2, (mark .. it.label .. string.rep(" ", w)):sub(1, w), fg, bg)
      M.at(x + 4, y + (i - 1) * 2 + 1, (tostring(it.help or "") .. string.rep(" ", w)):sub(1, w - 4), "gray")
    end
    if onDraw then onDraw(selected) end
    M.flush()
    local ev = M.event()
    if ev.type == "key" then
      if ev.key == "up" or ev.key == "k" then selected = selected > 1 and selected - 1 or #items
      elseif ev.key == "down" or ev.key == "j" or ev.key == "tab" then selected = selected < #items and selected + 1 or 1
      elseif ev.key == "enter" or ev.key == " " then return selected
      elseif ev.key == "esc" then return nil
      elseif tonumber(ev.key) and items[tonumber(ev.key)] then selected = tonumber(ev.key) end
    elseif ev.type == "click" then
      local i = math.floor((ev.y - y) / 2) + 1
      if ev.x >= x and ev.x < x + w and items[i] then
        if i == selected then return i end
        selected = i
      end
    elseif ev.type == "button" then
      return selected, ev
    end
  end
end

return M
