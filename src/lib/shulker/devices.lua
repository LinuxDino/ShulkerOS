-- OC2 device bus access through the HLAPI `devices` library that OC2 ships in /mnt/builtin/lib/lua.
local U = require("shulker.util")
local M = {}

local function addPath()
  for _, d in ipairs({ "/run/oc2/lib/lua", "/mnt/builtin/lib/lua" }) do
    if U.exists(d .. "/devices.lua") and not package.path:find(d, 1, true) then
      package.path = d .. "/?.lua;" .. d .. "/?/init.lua;" .. package.path
    end
  end
end

-- Long-running services (swarmd, the monitor, the dashboard) set daemonOnly: they use the bus only
-- through OC2's bus daemon (/run/oc2/bus), never by opening the virtio ports themselves. A process that
-- holds the ports keeps the daemon from starting, and then every other program gets "Resource busy".
M.daemonOnly = false
M.SOCKET = "/run/oc2/bus"

local bus
function M.bus()
  if bus then return bus end
  if M.daemonOnly and not U.exists(M.SOCKET) then
    return nil, "waiting for the OC2 bus daemon (" .. M.SOCKET .. ")"
  end
  addPath()
  local ok, b = pcall(require, "devices")
  if not ok then
    return nil, "no OC2 device bus: " .. tostring(b):gsub("^.-: ", "") ..
      " (this works inside an OC2 computer; is /mnt/builtin mounted?)"
  end
  bus = b
  return bus
end

function M.list()
  local b, err = M.bus()
  if not b then return nil, err end
  local ok, list = pcall(b.list, b)
  if not ok then return nil, tostring(list) end
  local out = {}
  for _, d in ipairs(list or {}) do
    local names = {}
    for _, n in ipairs(d.typeNames or {}) do names[#names + 1] = n end
    table.sort(names)
    out[#out + 1] = { id = d.deviceId, types = names }
  end
  table.sort(out, function(a, c) return (a.types[1] or "") < (c.types[1] or "") end)
  return out
end

-- device by id or type name -> id | nil, why
function M.resolve(which)
  local list, err = M.list()
  if not list then return nil, err end
  which = tostring(which or "")
  for _, d in ipairs(list) do if d.id == which then return d.id end end
  for _, d in ipairs(list) do
    for _, t in ipairs(d.types) do if t == which then return d.id end end
  end
  local names = {}
  for _, d in ipairs(list) do names[#names + 1] = table.concat(d.types, "/") end
  return nil, ("no device %q. Devices: %s"):format(which, #names > 0 and table.concat(names, ", ") or "none")
end

function M.methods(which)
  local id, err = M.resolve(which)
  if not id then return nil, err end
  local ok, m = pcall(bus.methods, bus, id)
  if not ok then return nil, tostring(m) end
  return m, id
end

function M.describeMethods(methods)
  local out = {}
  for _, m in ipairs(methods or {}) do
    local params = {}
    for i, p in ipairs(m.parameters or {}) do
      params[#params + 1] = (p.name or ("arg" .. i)) .. (p.type and (": " .. p.type) or "")
    end
    local line = ("%s(%s)%s"):format(m.name, table.concat(params, ", "), m.returnType and (": " .. m.returnType) or "")
    if m.description then line = line .. "\n    " .. m.description end
    for i, p in ipairs(m.parameters or {}) do
      if p.description then line = line .. ("\n    %s: %s"):format(p.name or ("arg" .. i), p.description) end
    end
    if m.returnValueDescription then line = line .. "\n    returns: " .. m.returnValueDescription end
    out[#out + 1] = line
  end
  return table.concat(out, "\n")
end

function M.invoke(which, method, args)
  local id, err = M.resolve(which)
  if not id then return nil, err end
  local ok, res = pcall(function() return table.pack(bus:invoke(id, method, table.unpack(args or {}))) end)
  if not ok then return nil, tostring(res) end
  return res
end

return M
