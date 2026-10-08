-- Orders: one command, split into pieces the swarm works on at the same time.
-- Used by `swarm order` and the Control Center (`control`). parse() turns a command line into
-- { label, kind, pieces = { { cmd, target, label, timeout } } }; the main node runs the pieces as jobs.
--
--   mine X1 Y1 Z1 X2 Y2 Z2      dig out a box: split into slices, any free drone takes the next one
--   home [all | DRONE...]       drones back to their chargers
--   go DRONE X Y Z              one drone to a place
--   run [on NAME|all] COMMAND   a shell command on one computer, every computer, or any free one
--   map 'COMMAND {}' ITEM...    one piece per item on free computers ({} is the item)
local U = require("shulker.util")

local M = {}

M.HELP = {
  "mine X1 Y1 Z1 X2 Y2 Z2    dig a box; split between all free drones",
  "home [all|DRONE...]       drones back to their chargers",
  "go DRONE X Y Z            send one drone somewhere",
  "run [on NAME|all] CMD     shell command on one / every / any free computer",
  "map 'CMD {}' ITEM...      one piece per item, spread over free computers",
  "stop ID                   stop an order (running pieces too)",
}

-- split a command line into words, keeping 'quoted' and "quoted" parts together
function M.words(line)
  local out, cur, quote, any = {}, {}, nil, false
  for ch in tostring(line):gmatch(".") do
    if quote then
      if ch == quote then quote = nil else cur[#cur + 1] = ch end
    elseif ch == "'" or ch == '"' then quote, any = ch, true
    elseif ch:match("%s") then
      if #cur > 0 or any then out[#out + 1] = table.concat(cur) cur, any = {}, false end
    else cur[#cur + 1] = ch end
  end
  if quote then return nil, "unclosed quote" end
  if #cur > 0 or any then out[#out + 1] = table.concat(cur) end
  return out
end

local function drones(status)
  local list = {}
  for _, n in ipairs(status and status.nodes or {}) do
    if n.stats and type(n.stats.drone) == "table" then list[#list + 1] = n end
  end
  return list
end
M.drones = drones

-- a box split into slices along its longer side; about `perPiece` blocks each, at least one per drone
function M.planMine(b, nDrones, perPiece)
  perPiece = perPiece or 256
  local x1, x2 = math.min(b[1], b[4]), math.max(b[1], b[4])
  local y1, y2 = math.min(b[2], b[5]), math.max(b[2], b[5])
  local z1, z2 = math.min(b[3], b[6]), math.max(b[3], b[6])
  local sx, sy, sz = x2 - x1 + 1, y2 - y1 + 1, z2 - z1 + 1
  local alongX = sx >= sz
  local len = alongX and sx or sz
  local volume = sx * sy * sz
  local n = math.max(nDrones or 1, math.ceil(volume / perPiece))
  n = math.max(1, math.min(n, len))
  local pieces, from = {}, 0
  for i = 1, n do
    local size = math.floor(len / n) + ((i <= len % n) and 1 or 0)
    local a, e = from, from + size - 1
    from = from + size
    local c
    if alongX then c = { x1 + a, y2, z1, x1 + e, y1, z2 } else c = { x1, y2, z1 + a, x2, y1, z1 + e } end
    pieces[#pieces + 1] = {
      cmd = ("drone mine %d %d %d %d %d %d"):format(c[1], c[2], c[3], c[4], c[5], c[6]),
      target = "drone", timeout = 3600,
      label = alongX and ("x %d..%d"):format(c[1], c[4]) or ("z %d..%d"):format(c[3], c[6]),
    }
  end
  return pieces, volume
end

-- parse a command into an order; status (from the main node) tells which drones/computers exist
function M.parse(line, status)
  local w, err = M.words(line)
  if not w then return nil, err end
  local verb = (w[1] or ""):lower()
  if verb == "" then return nil, "type a command (help lists them)" end

  if verb == "mine" then
    local b = {}
    for i = 2, 7 do b[#b + 1] = tonumber(w[i] or "") end
    if #b < 6 then return nil, "mine X1 Y1 Z1 X2 Y2 Z2 (two corners of the box)" end
    local ds = drones(status)
    local pieces, volume = M.planMine(b, math.max(1, #ds))
    return { kind = "mine", pieces = pieces,
             label = ("mine %d blocks (%d %d %d .. %d %d %d)"):format(volume, b[1], b[2], b[3], b[4], b[5], b[6]),
             note = #ds == 0 and "no drone has joined yet: the pieces wait for one" or
               ("%d pieces for %d drone%s"):format(#pieces, #ds, #ds == 1 and "" or "s") }

  elseif verb == "home" then
    local names = {}
    if not w[2] or w[2] == "all" then
      for _, d in ipairs(drones(status)) do if d.online then names[#names + 1] = d.name end end
    else
      for i = 2, #w do names[#names + 1] = w[i] end
    end
    if #names == 0 then return nil, "no drone online" end
    local pieces = {}
    for _, n in ipairs(names) do pieces[#pieces + 1] = { cmd = "drone home --dig", target = n, label = n, timeout = 900 } end
    return { kind = "home", label = "home: " .. table.concat(names, " "), pieces = pieces }

  elseif verb == "go" then
    local x, y, z = tonumber(w[3] or ""), tonumber(w[4] or ""), tonumber(w[5] or "")
    if not (w[2] and x and y and z) then return nil, "go DRONE X Y Z" end
    return { kind = "go", label = ("%s to %d %d %d"):format(w[2], x, y, z),
             pieces = { { cmd = ("drone go %d %d %d --dig"):format(x, y, z), target = w[2], label = w[2], timeout = 900 } } }

  elseif verb == "run" then
    local i, target = 2, "any"
    if w[2] == "on" and w[3] then target, i = w[3], 4 end
    local parts = {}
    for k = i, #w do parts[#parts + 1] = w[k] end
    if #parts == 0 then return nil, "run [on NAME|all] COMMAND" end
    local cmd = table.concat(parts, " ")
    local pieces = {}
    if target == "all" then
      for _, n in ipairs(status and status.nodes or {}) do
        if n.online then pieces[#pieces + 1] = { cmd = cmd, target = n.name, label = n.name } end
      end
      if #pieces == 0 then return nil, "no computer online" end
    else
      pieces[1] = { cmd = cmd, target = target, label = target }
    end
    return { kind = "run", label = "run: " .. cmd, pieces = pieces }

  elseif verb == "map" then
    local tmpl = w[2]
    if not tmpl or not tmpl:find("{}", 1, true) or not w[3] then return nil, "map 'COMMAND {}' ITEM..." end
    local pieces = {}
    for k = 3, #w do
      local item = w[k]
      pieces[#pieces + 1] = { cmd = (tmpl:gsub("{}", function() return U.q(item) end)), target = "any", label = item }
    end
    return { kind = "map", label = ("map %s over %d items"):format(tmpl, #pieces), pieces = pieces }
  end
  return nil, "unknown command " .. verb .. " (help lists them)"
end

-- a progress bar string: done/total, w wide
function M.bar(done, total, w)
  local f = total > 0 and math.floor(done / total * w + 0.5) or 0
  return string.rep("a", f), string.rep("q", w - f)
end

return M
