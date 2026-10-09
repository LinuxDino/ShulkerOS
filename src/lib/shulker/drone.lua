-- Drones: OC2 robots running Shulker OS. Wraps OC2's `robot` Lua library (synchronous moves) and the
-- module devices (scanner, block_operations, inventory_operations) found on the robot's device bus.
--
-- Positions are relative to where the robot was placed (or last calibrated): x grows east, y up,
-- z south (OC2's robot compass). Put a charger at the start position: "home" is (0, 0, 0).
local U = require("shulker.util")
local devices = require("shulker.devices")

local M = {}

local robotLib, robotErr
function M.robot()
  if robotLib then return robotLib end
  local bus, err = devices.bus()
  if not bus then robotErr = err return nil, err end
  local ok, lib = pcall(require, "robot")
  if not ok then robotErr = "not a robot (" .. tostring(lib):gsub("^.-: ", "") .. ")" return nil, robotErr end
  robotLib = lib
  return robotLib
end

function M.isDrone()
  return M.robot() ~= nil
end

local function module(typeName)
  local bus = devices.bus()
  if not bus then return nil end
  local ok, dev = pcall(bus.find, bus, typeName)
  if ok then return dev end
end
M.module = module

-- position as numbers {x, y, z}
function M.position()
  local r = M.robot()
  if not r then return nil end
  local ok, p = pcall(r.position)
  if not ok or type(p) ~= "table" then return nil end
  return { x = tonumber(p.x) or 0, y = tonumber(p.y) or 0, z = tonumber(p.z) or 0 }
end

-- a small status table for heartbeats and `drone status`; light = battery and position only
-- (the module list costs one bus call per module type, so heartbeats ask for it now and then)
function M.info(light)
  local r = M.robot()
  if not r then return nil end
  local info = {}
  pcall(function() info.energy = tonumber(r.energy()) end)
  pcall(function() info.capacity = tonumber(r.capacity()) end)
  pcall(function() info.facing = r.facing() end)
  info.pos = M.position()
  if light then
    if info.energy and info.capacity and info.capacity > 0 then
      info.charge = math.floor(info.energy / info.capacity * 100 + 0.5)
    end
    return info
  end
  pcall(function() info.slot = r.slot() end)
  local mods = {}
  for _, m in ipairs({ "scanner", "block_operations", "inventory_operations", "tank_operations", "crafting" }) do
    if module(m) then mods[#mods + 1] = m end
  end
  info.modules = mods
  if info.energy and info.capacity and info.capacity > 0 then
    info.charge = math.floor(info.energy / info.capacity * 100 + 0.5)
  end
  return info
end

---------------------------------------------------------------- digging and placing
-- The block operations module has a cooldown after every dig or place (1 s, up to 15 s for hard blocks);
-- a call during it returns false at once. These wait it out: only a block that still stands after
-- 16 s of trying (bedrock, a protected block) counts as unbreakable.
local okSock, sock = pcall(require, "socket")
function M.sleep(s)
  if okSock and sock.sleep then sock.sleep(s) else os.execute("sleep " .. math.max(1, math.ceil(s))) end
end

function M.excavate(side)
  local r, ops = M.robot(), module("block_operations")
  if not ops then return false end
  local waited = 0
  while waited <= 16 do
    local okD, solid = pcall(r.detect, side)
    if okD and not solid then return true end
    local ok, res = pcall(ops.excavate, ops, side)
    if ok and res then return true end
    M.sleep(0.5)
    waited = waited + 0.5
  end
  return false
end

function M.place(side)
  local ops = module("block_operations")
  if not ops then return false end
  for _ = 1, 32 do
    local ok, res = pcall(ops.place, ops, side)
    if ok and res then return true end
    M.sleep(0.5)
  end
  return false
end

---------------------------------------------------------------- movement
local TURN_ORDER = { "north", "east", "south", "west" }
local DELTA = { north = { 0, -1 }, south = { 0, 1 }, east = { 1, 0 }, west = { -1, 0 } }

function M.turn(dir)
  local r = assert(M.robot())
  if dir == "around" then return r.turn("left") and r.turn("left") end
  return r.turn(dir)
end

function M.face(want)
  local r = assert(M.robot())
  for _ = 1, 4 do
    local f = r.facing()
    if f == want then return true end
    local i
    for k, v in ipairs(TURN_ORDER) do if v == f then i = k end end
    local j
    for k, v in ipairs(TURN_ORDER) do if v == want then j = k end end
    if not i or not j then return false end
    if (j - i) % 4 == 3 then r.turn("left") else r.turn("right") end
  end
  return r.facing() == want
end

-- one step; dig = break what is in the way (needs a block operations module)
function M.step(dir, dig)
  local r = assert(M.robot())
  if r.move(dir) then return true end
  if dig and module("block_operations") then
    local side = dir == "upward" and "up" or dir == "downward" and "down" or "front"
    for _ = 1, 3 do                       -- gravel or sand can fall into the gap again
      if not M.excavate(side) then return false end
      if r.move(dir) then return true end
    end
  end
  return false
end

-- go to x y z (relative to the start position) along the axes; returns true or false, why
function M.go(x, y, z, dig)
  local r = assert(M.robot())
  for _ = 1, 4096 do
    local p = M.position()
    if not p then return false, "no position" end
    if p.x == x and p.y == y and p.z == z then return true end
    local ok
    if p.y < y then ok = M.step("upward", dig)
    elseif p.y > y then ok = M.step("downward", dig)
    elseif p.x ~= x then
      M.face(p.x < x and "east" or "west")
      ok = M.step("forward", dig)
    else
      M.face(p.z < z and "south" or "north")
      ok = M.step("forward", dig)
    end
    if not ok then
      -- blocked: try the vertical detour once (up, then on)
      if p.y == y and M.step("upward", false) then
        ok = true
      else
        return false, ("blocked at %d %d %d (use --dig to dig through)"):format(p.x, p.y, p.z)
      end
    end
    local e = M.info()
    if e and e.charge and e.charge < 3 then return false, "out of energy" end
  end
  return false, "too far"
end

---------------------------------------------------------------- shared coordinates
-- Each robot counts from where it was placed (its home). To give many drones one area, tell each one
-- where its home is in world coordinates (F3): `drone origin X Y Z`. Orders then use world coordinates.
local function confPath() return U.etcdir() .. "/drone.conf" end

function M.origin()
  for _, l in ipairs(U.lines(confPath())) do
    local x, y, z = l:match("^origin=(%-?%d+),(%-?%d+),(%-?%d+)")
    if x then return { x = tonumber(x), y = tonumber(y), z = tonumber(z) } end
  end
end

function M.setOrigin(x, y, z)
  U.mkdir(U.etcdir())
  U.write(confPath(), ("# where this drone's home (its charger spot) is in the world\norigin=%d,%d,%d\n"):format(x, y, z))
end

-- world (or, without an origin, home-relative) coordinates -> the robot's own
function M.toLocal(x, y, z)
  local o = M.origin()
  if not o then return x, y, z end
  return x - o.x, y - o.y, z - o.z
end

function M.toWorld(p)
  local o = M.origin()
  if not o or not p then return p end
  return { x = p.x + o.x, y = p.y + o.y, z = p.z + o.z }
end

---------------------------------------------------------------- long trips: the travel corridor
-- Trips home (charging, emptying) and out to the work area must not cut through the base. They go up or
-- down at the current spot to the travel height, across at that height, then straight down/up. The last
-- part into the charger spot never digs: the blocks above each charger (up to the travel height) must be
-- free. Travel height: `drone travel Y` (world y), default 3 blocks above the charger.
function M.travelY()
  for _, l in ipairs(U.lines(confPath())) do
    local v = tonumber(l:match("^travel=(%-?%d+)") or "")
    if v then
      local o = M.origin()
      return o and (v - o.y) or v
    end
  end
  return 3
end

function M.setTravel(y)
  local lines = {}
  for _, l in ipairs(U.lines(confPath())) do if not l:match("^travel=") then lines[#lines + 1] = l end end
  lines[#lines + 1] = ("travel=%d"):format(y)
  U.mkdir(U.etcdir())
  U.write(confPath(), table.concat(lines, "\n") .. "\n")
end

-- to a work spot (local coordinates) through the corridor
function M.travelTo(x, y, z)
  local p = M.position()
  if not p then return false, "no position" end
  local T = M.travelY()
  local ok, err
  if p.x == 0 and p.z == 0 and p.y >= 0 and p.y <= T then
    ok, err = M.go(0, T, 0, false)                 -- out of the home column without digging
    if not ok then return false, "the blocks above the charger are not free: " .. tostring(err) end
  else
    ok, err = M.go(p.x, T, p.z, true)
    if not ok then return false, err end
  end
  ok, err = M.go(x, T, z, true)
  if not ok then return false, err end
  return M.go(x, y, z, true)
end

-- home (0 0 0) through the corridor
function M.goHome()
  local p = M.position()
  if not p then return false, "no position" end
  local T = M.travelY()
  local ok, err
  if not (p.x == 0 and p.z == 0) then
    ok, err = M.go(p.x, T, p.z, true)
    if not ok then return false, err end
    ok, err = M.go(0, T, 0, true)
    if not ok then return false, err end
  end
  ok, err = M.go(0, 0, 0, false)
  if not ok then return false, "the way down to the charger is blocked: " .. tostring(err) end
  return true
end

---------------------------------------------------------------- work: mining a box
local function charge()
  local i = M.info(true)
  return i and i.charge or 100
end
M.now = os.time

-- When must it turn back? A robot's battery lasts only about 25 minutes (CPU, memory, drive and modules
-- draw power all the time) and it flies one block a second, so a fixed "home at 20 %" strands drones
-- that work far from their charger. It measures how fast its charge drops and heads home while the trip
-- (through the travel corridor) still fits, with half again as margin, plus 5 %.
local drain = { t = nil, c = nil, rate = 100 / 1500 }   -- percent per second; ~25 min to start with
function M.observeCharge(c)
  local t = M.now()
  if drain.t and t > drain.t and c < drain.c then
    local r = (drain.c - c) / (t - drain.t)
    drain.rate = math.max(drain.rate * 0.7 + r * 0.3, 0.01)
  end
  if not drain.t or c < drain.c or c > drain.c + 5 then drain.t, drain.c = t, c end
end

function M.tripHome(p)
  p = p or M.position()
  if not p then return 0 end
  local T = M.travelY()
  if p.x == 0 and p.z == 0 then return math.abs(p.y) end
  return math.abs(p.y - T) + math.abs(p.x) + math.abs(p.z) + math.abs(T)
end

function M.needsCharge(low)
  local c = charge()
  M.observeCharge(c)
  local reserve = drain.rate * M.tripHome() * 1.5 + 5
  return c < math.max(low or 0, reserve), c, reserve
end

-- go home, wait on the charger until `full` percent, come back to where we were
function M.recharge(full, log)
  local back = M.position()
  log("battery low: going home to charge")
  local ok, err = M.goHome()
  if not ok then return nil, "cannot get home: " .. tostring(err) end
  local waited = 0
  while charge() < (full or 90) do
    M.sleep(5)
    waited = waited + 5
    if waited > 1800 then return nil, "not charging at home: is the charger powered and under the robot?" end
  end
  log("charged, back to work")
  if back then
    local ok2, err2 = M.travelTo(back.x, back.y, back.z)
    if not ok2 then return nil, err2 end
  end
  return true
end

-- dig out every block of the box (two corners, in world or home-relative coordinates), top layer
-- first, row by row; goes home to charge below `low` percent. Returns blocks visited | nil, why
function M.mine(x1, y1, z1, x2, y2, z2, opts)
  opts = opts or {}
  local log = opts.log or function() end
  local low = opts.low or 20
  x1, y1, z1 = M.toLocal(x1, y1, z1)
  x2, y2, z2 = M.toLocal(x2, y2, z2)
  if x1 > x2 then x1, x2 = x2, x1 end
  if y1 > y2 then y1, y2 = y2, y1 end
  if z1 > z2 then z1, z2 = z2, z1 end
  local total = (x2 - x1 + 1) * (y2 - y1 + 1) * (z2 - z1 + 1)
  local done = 0
  for y = y2, y1, -1 do
    local zs, ze, zd = z1, z2, 1
    for x = x1, x2 do
      for z = zs, ze, zd do
        if M.needsCharge(low) then
          local ok, err = M.recharge(opts.full or 95, log)
          if not ok then return nil, err end
        end
        local ok, err = M.go(x, y, z, true)
        if not ok then return nil, ("stuck at %d %d %d: %s"):format(x, y, z, tostring(err)) end
        done = done + 1
        if opts.progress then opts.progress(done, total) end
      end
      zs, ze, zd = ze, zs, -zd
    end
  end
  return done
end

---------------------------------------------------------------- work: clearing a box (everything)
-- Clears every block of a box in passes of three layers: the drone flies along the middle layer and
-- digs the block in front, above and below. Its inventory (12 slots) fills fast, so it carries a dump
-- block: an inventory block it places above itself, empties everything into and digs up again. A trash
-- can (items are deleted) or an ender chest (items go to the linked storage at your base) are good dump
-- blocks. Without one it flies home and empties into the inventory in front of its charger (north).
-- Spare pickaxes in the inventory are used when the current one wears out.
M.TOOL_WORDS = { "pickaxe", "paxel", "drill", "meka_tool", "mekatool", "hammer", "excavator" }
M.DUMP_WORDS = { "trash", "ender_chest", "enderchest", "void" }

local function itemId(st) return type(st) == "table" and tostring(st.id or st.item or st.name or "") or nil end
local function isAny(id, words)
  id = (id or ""):lower()
  for _, w in ipairs(words) do if id:find(w, 1, true) then return true end end
  return false
end

-- extra dump words from /etc/shulker/drone.conf: dump=modid:block_name
local function dumpWords()
  local words = { table.unpack(M.DUMP_WORDS) }
  for _, l in ipairs(U.lines(confPath())) do
    local v = l:match("^dump=(%S+)")
    if v then table.insert(words, 1, v:lower()) end
  end
  return words
end

-- the drone's 12 slots: which hold tools, the dump block, and other items (junk)
function M.slots()
  local r = assert(M.robot())
  local out = { tools = {}, dump = nil, junk = {}, free = 0 }
  local dw = dumpWords()
  for s = 0, 11 do
    local ok, st = pcall(r.stack, s)
    local id = ok and itemId(st) or nil
    if not id or id == "" then out.free = out.free + 1
    elseif isAny(id, M.TOOL_WORDS) then out.tools[#out.tools + 1] = s
    elseif not out.dump and isAny(id, dw) then out.dump = s
    else out.junk[#out.junk + 1] = s end
  end
  return out
end

-- select a usable pickaxe; false when none is left
function M.selectTool()
  local r = assert(M.robot())
  local ops = module("block_operations")
  for _, s in ipairs(M.slots().tools) do
    r.slot(s)
    local ok, left = pcall(ops.durability, ops)
    if not ok or left == nil or tonumber(left) == nil or tonumber(left) > 8 then return true end
  end
  return false
end

local function digAll(side)
  local r = M.robot()
  for _ = 1, 10 do                      -- gravel and sand fall back in
    if not M.excavate(side) then return false end
    local okD, solid = pcall(r.detect, side)
    if okD and not solid then return true end
  end
  return true
end

-- empty the inventory: into the dump block placed above (or below), else at home
function M.dump(log)
  local r = assert(M.robot())
  local ops, inv = module("block_operations"), module("inventory_operations")
  if not inv then return nil, "needs an inventory operations module to empty its inventory" end
  local sl = M.slots()
  if #sl.junk == 0 then return true end
  -- drop only into a real inventory: OC2's drop throws items on the ground when there is none
  local function emptyInto(side)
    local okC, cnt = pcall(inv.getItemSlotCount, inv, side)
    if not okC or not tonumber(cnt) or tonumber(cnt) < 1 then return false end
    for _, s in ipairs(sl.junk) do
      r.slot(s)
      for _ = 1, 4 do
        local ok, n = pcall(inv.drop, inv, 64, side)
        if not ok or not n or n == 0 then break end
      end
    end
    return true
  end
  if sl.dump then
    for _, side in ipairs({ "up", "down" }) do
      M.selectTool()
      if digAll(side) then
        r.slot(sl.dump)
        if M.place(side) then
          local emptied = emptyInto(side)
          M.selectTool()
          M.excavate(side)                  -- the dump block comes back into the inventory
          if emptied then return true end
          log("the dump block is not an inventory (use a trash can or an ender chest)")
          break
        end
      end
    end
    log("could not place the dump block here, emptying at home")
  end
  -- no dump block: fly home and drop everything into the inventory north of the charger
  local back = M.position()
  local ok, err = M.goHome()
  if not ok then return nil, "cannot get home to empty: " .. tostring(err) end
  M.face("north")
  local emptied = emptyInto("front")
  M.selectTool()
  if not emptied then return nil, "nothing to empty into: give it a dump block, or put a chest north of its charger" end
  if back then
    local ok2, err2 = M.travelTo(back.x, back.y, back.z)
    if not ok2 then return nil, err2 end
  end
  if #M.slots().junk > 0 then return nil, "the inventory at home (north of the charger) is full or missing" end
  return true
end

-- clear the box (world or home-relative corners); returns blocks handled | nil, why
function M.clear(x1, y1, z1, x2, y2, z2, opts)
  opts = opts or {}
  local log = opts.log or function() end
  if not module("block_operations") then return nil, "needs a block operations module" end
  x1, y1, z1 = M.toLocal(x1, y1, z1)
  x2, y2, z2 = M.toLocal(x2, y2, z2)
  if x1 > x2 then x1, x2 = x2, x1 end
  if y1 > y2 then y1, y2 = y2, y1 end
  if z1 > z2 then z1, z2 = z2, z1 end
  if not M.selectTool() then return nil, "no pickaxe in the inventory" end
  local cells = (x2 - x1 + 1) * (z2 - z1 + 1)
  local passes = {}
  local y = y2 - 1
  while y + 1 >= y1 do passes[#passes + 1] = math.max(y, y1) y = y - 3 end
  local total, done = cells * #passes, 0
  for _, py in ipairs(passes) do
    local zs, ze, zd = z1, z2, 1
    for x = x1, x2 do
      for z = zs, ze, zd do
        if M.needsCharge(opts.low or 15) then
          local ok, err = M.recharge(opts.full or 95, log)
          if not ok then return nil, err end
        end
        if M.slots().free < 2 then
          local ok, err = M.dump(log)
          if not ok then return nil, err end
        end
        if not M.selectTool() then return nil, "out of pickaxes (put spares in its inventory)" end
        local ok, err
        if done == 0 then ok, err = M.travelTo(x, py, z) else ok, err = M.go(x, py, z, true) end
        if not ok then return nil, ("stuck at %d %d %d: %s"):format(x, py, z, tostring(err)) end
        if py + 1 <= y2 then digAll("up") end
        if py - 1 >= y1 then digAll("down") end
        done = done + 1
        if opts.progress then opts.progress(done, total) end
      end
      zs, ze, zd = ze, zs, -zd
    end
  end
  return (x2 - x1 + 1) * (y2 - y1 + 1) * (z2 - z1 + 1)
end

---------------------------------------------------------------- sensing
function M.inspect(side)
  local sc = module("scanner")
  if not sc then return nil, "no scanner module" end
  local ok, res = pcall(sc.inspect, sc, side or "front")
  if not ok then return nil, tostring(res) end
  return res
end

-- 7x7x7 hardness scan summary: how many blocks per hardness band, plus entities
function M.scan()
  local sc = module("scanner")
  if not sc then return nil, "no scanner module" end
  local ok, res = pcall(sc.scan, sc)
  if not ok then return nil, tostring(res) end
  local bands = { air = 0, soft = 0, stone = 0, hard = 0 }
  local h = res and res.hardness
  if type(h) == "string" then
    for i = 1, #h do
      local v = h:byte(i)
      if v == 0 then bands.air = bands.air + 1 elseif v < 15 then bands.soft = bands.soft + 1
      elseif v < 30 then bands.stone = bands.stone + 1 else bands.hard = bands.hard + 1 end
    end
  elseif type(h) == "table" then
    for _, v in ipairs(h) do
      v = tonumber(v) or 0
      if v == 0 then bands.air = bands.air + 1 elseif v < 15 then bands.soft = bands.soft + 1
      elseif v < 30 then bands.stone = bands.stone + 1 else bands.hard = bands.hard + 1 end
    end
  end
  return { bands = bands, entities = res and res.entities or {} }
end

return M
