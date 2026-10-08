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

-- a small status table for heartbeats and `drone status`
function M.info()
  local r = M.robot()
  if not r then return nil end
  local info = {}
  pcall(function() info.energy = tonumber(r.energy()) end)
  pcall(function() info.capacity = tonumber(r.capacity()) end)
  pcall(function() info.facing = r.facing() end)
  info.pos = M.position()
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
  if dig then
    local ops = module("block_operations")
    if ops then
      local side = dir == "upward" and "up" or dir == "downward" and "down" or "front"
      pcall(ops.excavate, ops, side)
      return r.move(dir)
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

---------------------------------------------------------------- work: mining a box
local function charge()
  local i = M.info()
  return i and i.charge or 100
end

-- go home, wait on the charger until `full` percent, come back to where we were
function M.recharge(full, log)
  local back = M.position()
  log("battery low: going home to charge")
  local ok, err = M.go(0, 0, 0, true)
  if not ok then return nil, "cannot get home: " .. tostring(err) end
  local waited = 0
  while charge() < (full or 90) do
    os.execute("sleep 5")
    waited = waited + 5
    if waited > 1800 then return nil, "not charging at home: is the charger powered and under the robot?" end
  end
  log("charged, back to work")
  if back then
    local ok2, err2 = M.go(back.x, back.y, back.z, true)
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
        if charge() < low then
          local ok, err = M.recharge(opts.full or 90, log)
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
