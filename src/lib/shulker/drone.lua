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
