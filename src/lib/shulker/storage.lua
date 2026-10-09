-- Inventories and tanks on this computer's device bus, from any mod: OC2 sees every block that holds
-- items, fluids or energy (chests, AE2 / Refined Storage interfaces, Sophisticated Storage, drawers,
-- Mekanism tanks and cubes, ...) through a bus interface, as item_handler / fluid_handler /
-- energy_storage devices. Name a bus interface with the wrench to give an inventory a readable name.
local devices = require("shulker.devices")

local M = {}
M.MAX_SLOTS = 512          -- big inventories (a drawer controller) are read only this far

local GENERIC = { item_handler = true, fluid_handler = true, energy_storage = true }

local function call(id, method, ...)
  local bus = devices.bus()
  if not bus then return nil end
  local ok, r = pcall(bus.invoke, bus, id, method, ...)
  if ok then return r end
end

-- a readable name: the bus interface's custom name if it has one, else "inventory N" / "tank N"
local function label(d, kind, n)
  for _, t in ipairs(d.types) do
    if not GENERIC[t] then return t end
  end
  return ("%s %d"):format(kind, n)
end

-- { items = { {id, name} }, fluids = {...}, energy = {...} }
function M.list()
  local out = { items = {}, fluids = {}, energy = {} }
  local list, err = devices.list()
  if not list then return nil, err end
  for _, d in ipairs(list) do
    local has = {}
    for _, t in ipairs(d.types) do has[t] = true end
    if has.item_handler then out.items[#out.items + 1] = { id = d.id, name = label(d, "inventory", #out.items + 1) } end
    if has.fluid_handler then out.fluids[#out.fluids + 1] = { id = d.id, name = label(d, "tank", #out.fluids + 1) } end
    if has.energy_storage then out.energy[#out.energy + 1] = { id = d.id, name = label(d, "energy", #out.energy + 1) } end
  end
  return out
end

-- item stacks come back as tables with id ("minecraft:diamond") and count
local function stackId(st)
  if type(st) ~= "table" then return nil end
  return st.id or (type(st.item) == "table" and st.item.id) or st.item
end

-- { slots, used, total, items = { [id] = count }, truncated }
function M.scanItems(id, maxSlots)
  local slots = tonumber(call(id, "getItemSlotCount")) or 0
  local limit = math.min(slots, maxSlots or M.MAX_SLOTS)
  local r = { slots = slots, used = 0, total = 0, items = {}, truncated = slots > limit }
  for s = 0, limit - 1 do
    local st = call(id, "getItemStackInSlot", s)
    local name = stackId(st)
    if name then
      local n = tonumber(st.count) or 1
      r.used, r.total = r.used + 1, r.total + n
      r.items[name] = (r.items[name] or 0) + n
    end
  end
  return r
end

-- { tanks = { {fluid, amount, capacity} }, amount, capacity }
function M.scanFluids(id)
  local n = tonumber(call(id, "getFluidTankCount")) or 0
  local r = { tanks = {}, amount = 0, capacity = 0 }
  for t = 0, math.min(n, 16) - 1 do
    local f = call(id, "getFluidInTank", t)
    local cap = tonumber(call(id, "getFluidTankCapacity", t)) or 0
    local amount = type(f) == "table" and tonumber(f.amount) or 0
    r.tanks[#r.tanks + 1] = { fluid = type(f) == "table" and f.id or nil, amount = amount, capacity = cap }
    r.amount, r.capacity = r.amount + amount, r.capacity + cap
  end
  return r
end

-- "minecraft:diamond_ore" matches "diamond", "diamond ore", "minecraft:diamond_ore"
function M.matches(id, word)
  word = tostring(word or ""):lower():gsub("%s+", "_")
  return word == "" or tostring(id):lower():find(word, 1, true) ~= nil
end

-- every item on this computer matching word: { { item, count, where = { {name, count} } } }, sorted
function M.find(word, maxSlots)
  local inv, err = M.list()
  if not inv then return nil, err end
  local found = {}
  for _, d in ipairs(inv.items) do
    local r = M.scanItems(d.id, maxSlots)
    for item, n in pairs(r.items) do
      if M.matches(item, word) then
        local f = found[item]
        if not f then f = { item = item, count = 0, where = {} } found[item] = f end
        f.count = f.count + n
        f.where[#f.where + 1] = { name = d.name, count = n }
      end
    end
  end
  local list = {}
  for _, f in pairs(found) do list[#list + 1] = f end
  table.sort(list, function(a, b) return a.count > b.count end)
  return list
end

-- search every computer of the swarm: call(msg) talks to the main node (swarm.call with the right conf).
-- Returns { list = { {item, count, where = { {host, count} }} }, asked, answered } | nil, err
function M.swarmFind(call, word, timeout)
  local U = require("shulker.util")
  local json = require("shulker.json")
  local st, err = call({ op = "status" })
  if not st then return nil, err end
  local ids = {}
  for _, n in ipairs(st.nodes or {}) do
    local drone = n.stats and type(n.stats.drone) == "table"
    if n.online and not drone then
      local r = call({ op = "submit", cmd = "storage find " .. U.q(word) .. " --json", target = n.name, timeout = 120 })
      if r and r.ids then for _, id in ipairs(r.ids) do ids[#ids + 1] = id end end
    end
  end
  if #ids == 0 then return nil, "no computer online" end
  local deadline = os.time() + (timeout or 150)
  local jobs
  repeat
    os.execute("sleep 2")
    local r = call({ op = "jobs", ids = json.array(ids), full = true })
    jobs = r and r.jobs or {}
    local open = 0
    for _, j in ipairs(jobs) do if j.state == "queued" or j.state == "running" then open = open + 1 end end
  until open == 0 or os.time() > deadline
  local total, answered = {}, 0
  for _, j in ipairs(jobs) do
    local line = tostring(j.out or ""):match("(%b{})%s*$")
    local ok, d = pcall(json.decode, line or "")
    if ok and type(d) == "table" and type(d.found) == "table" then
      answered = answered + 1
      for _, f in ipairs(d.found) do
        local t = total[f.item]
        if not t then t = { item = f.item, count = 0, where = {} } total[f.item] = t end
        t.count = t.count + (tonumber(f.count) or 0)
        t.where[#t.where + 1] = { host = j.node or d.host, count = tonumber(f.count) or 0 }
      end
    end
  end
  local list = {}
  for _, t in pairs(total) do list[#list + 1] = t end
  table.sort(list, function(a, b) return a.count > b.count end)
  return { list = list, asked = #ids, answered = answered }
end

-- a short name for an item id: "minecraft:diamond_ore" -> "diamond ore", other mods keep their prefix
function M.short(id)
  id = tostring(id)
  local ns, name = id:match("^([^:]+):(.+)$")
  if not ns then return id end
  name = name:gsub("_", " ")
  return ns == "minecraft" and name or (ns .. ":" .. name)
end

return M
