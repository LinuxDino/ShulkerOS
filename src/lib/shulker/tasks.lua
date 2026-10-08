-- The task list: a plain todo.txt file (one task per line), readable with cat and editable with nano.
--   (A) 2026-10-08 Build the reactor +base @overworld
--   x 2026-10-09 2026-10-08 Craft 64 cables
-- (A)/(B)/(C) = high/medium/low priority; "x <done date>" marks a finished task.
-- A task's number is its line number in the file.
local U = require("shulker.util")
local M = {}

function M.path() return os.getenv("SHULKER_TASKS") or (U.userdir() .. "/tasks.txt") end
function M.donePath() return (M.path():gsub("%.txt$", "")) .. ".done.txt" end

local PRI = { a = "A", high = "A", h = "A", ["1"] = "A", ["!!"] = "A",
              b = "B", medium = "B", med = "B", m = "B", ["2"] = "B", ["!"] = "B",
              c = "C", low = "C", l = "C", ["3"] = "C" }
function M.priority(p)
  if p == nil or p == "" then return nil end
  p = tostring(p):lower()
  if p == "none" or p == "-" or p == "0" then return false end
  return PRI[p]
end
M.PRI_NAME = { A = "high", B = "medium", C = "low" }

local function today() return os.date("%Y-%m-%d") end

function M.parse(line, id)
  local t = { id = id, raw = line, done = false }
  local rest = line
  local done, d1 = rest:match("^(x) (%d%d%d%d%-%d%d%-%d%d) ")
  if done then
    t.done, t.completed = true, d1
    rest = rest:sub(14)
  elseif rest:match("^x ") then
    t.done = true
    rest = rest:sub(3)
  end
  local pri = rest:match("^%(([A-Z])%) ")
  if pri then t.pri = pri rest = rest:sub(5) end
  local created = rest:match("^(%d%d%d%d%-%d%d%-%d%d) ")
  if created then t.created = created rest = rest:sub(12) end
  -- a done task keeps its priority as pri:X (todo.txt convention)
  local keep = rest:match(" pri:([A-Z])$")
  if keep and t.done then t.pri = keep rest = rest:gsub(" pri:[A-Z]$", "") end
  t.text = rest
  t.projects, t.contexts = {}, {}
  for p in (" " .. rest):gmatch("%s%+(%S+)") do t.projects[#t.projects + 1] = p end
  for c in (" " .. rest):gmatch("%s@(%S+)") do t.contexts[#t.contexts + 1] = c end
  return t
end

function M.format(t)
  local parts = {}
  if t.done then
    parts[#parts + 1] = "x " .. (t.completed or today())
    if t.created then parts[#parts + 1] = t.created end
    parts[#parts + 1] = t.text .. (t.pri and (" pri:" .. t.pri) or "")
  else
    if t.pri then parts[#parts + 1] = "(" .. t.pri .. ")" end
    if t.created then parts[#parts + 1] = t.created end
    parts[#parts + 1] = t.text
  end
  return table.concat(parts, " ")
end

function M.load()
  local out = {}
  for i, line in ipairs(U.lines(M.path())) do
    if line:match("%S") then out[#out + 1] = M.parse(line, i) else out[#out + 1] = { id = i, blank = true, raw = line } end
  end
  return out
end

local function save(list)
  U.mkdir(U.userdir(), "700")
  local lines = {}
  for _, t in ipairs(list) do lines[#lines + 1] = t.blank and "" or M.format(t) end
  return U.write(M.path(), table.concat(lines, "\n") .. (#lines > 0 and "\n" or ""))
end
M.save = save

local function get(list, id)
  id = tonumber(id)
  local t = id and list[id]
  if not t or t.blank then return nil, ("no task #%s (see `task list`)"):format(tostring(id)) end
  return t
end

function M.add(text, pri)
  text = U.trim((tostring(text or ""):gsub("[\r\n]+", " ")))
  if text == "" then return nil, "empty task" end
  -- "!!" / "!" at the start also set the priority, as in WardenOS's To-Do
  local bang = text:match("^(!!?)%s+")
  if bang and pri == nil then pri = bang text = U.trim(text:sub(#bang + 1)) end
  local p = M.priority(pri)
  local list = M.load()
  local t = { text = text, pri = p or nil, created = today(), done = false }
  list[#list + 1] = t
  local ok, err = save(list)
  if not ok then return nil, err end
  t.id = #list
  return t
end

function M.update(id, changes)
  local list = M.load()
  local t, err = get(list, id)
  if not t then return nil, err end
  if changes.done ~= nil then
    t.done = changes.done and true or false
    t.completed = t.done and today() or nil
  end
  if changes.pri ~= nil then
    local p = M.priority(changes.pri)
    if p == nil then return nil, "priority: high, medium, low (or A, B, C) or none" end
    t.pri = p or nil
  end
  if changes.text ~= nil then
    local text = U.trim((tostring(changes.text):gsub("[\r\n]+", " ")))
    if text == "" then return nil, "empty task" end
    t.text = text
  end
  local ok, serr = save(list)
  if not ok then return nil, serr end
  return t
end

function M.remove(id)
  local list = M.load()
  local t, err = get(list, id)
  if not t then return nil, err end
  table.remove(list, tonumber(id))
  local ok, serr = save(list)
  if not ok then return nil, serr end
  return t
end

-- move finished tasks to tasks.done.txt
function M.archive()
  local list, keep, moved = M.load(), {}, {}
  for _, t in ipairs(list) do
    if t.done then moved[#moved + 1] = M.format(t) elseif not t.blank then keep[#keep + 1] = t end
  end
  if #moved == 0 then return 0 end
  U.append(M.donePath(), table.concat(moved, "\n") .. "\n")
  save(keep)
  return #moved
end

-- filter: "open" (default), "done", "all", or a word / +project / @context to search for
function M.select(filter)
  filter = filter or "open"
  local out = {}
  for _, t in ipairs(M.load()) do
    if not t.blank then
      local okF
      if filter == "all" then okF = true
      elseif filter == "open" then okF = not t.done
      elseif filter == "done" then okF = t.done
      else okF = t.text:lower():find(filter:lower(), 1, true) ~= nil end
      if okF then out[#out + 1] = t end
    end
  end
  -- open before done, then by priority, then by number
  table.sort(out, function(a, b)
    if a.done ~= b.done then return not a.done end
    local pa, pb = a.pri or "Z", b.pri or "Z"
    if pa ~= pb then return pa < pb end
    return a.id < b.id
  end)
  return out
end

-- one line for the terminal
function M.render(t, color)
  local c = color or function(_, s) return s end
  local box = t.done and c("ok", "[x]") or c("dim", "[ ]")
  local pri = ""
  if t.pri == "A" then pri = c("err", "!! ") elseif t.pri == "B" then pri = c("warn", "!  ") elseif t.pri == "C" then pri = c("dim", ".  ") else pri = "   " end
  local text = t.text:gsub("(%+%S+)", function(p) return c("soft", p) end):gsub("(@%S+)", function(p) return c("info", p) end)
  if t.done then text = c("dim", t.text) end
  return ("%s %s %s%s"):format(c("accent", ("%3d"):format(t.id)), box, pri, text)
end

-- plain text for Claude
function M.plain(list)
  if #list == 0 then return "(no tasks)" end
  local out = {}
  for _, t in ipairs(list) do
    out[#out + 1] = ("#%d [%s] %s%s%s"):format(t.id, t.done and "x" or " ",
      t.pri and ("(" .. M.PRI_NAME[t.pri] .. ") ") or "", t.text,
      t.created and ("  created " .. t.created) or "")
  end
  return table.concat(out, "\n")
end

return M
