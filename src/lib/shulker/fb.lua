-- Drawing on an OC2 projector: a 640x480 RGB565 (little-endian) Linux framebuffer at /dev/fbN.
-- Draws straight into the device with seek + write, one row run at a time.
local U = require("shulker.util")
local font = require("shulker.font8x16")

local M = {}

function M.find()
  for i = 0, 7 do
    local dev = "/dev/fb" .. i
    if U.exists(dev) then
      local size = U.read("/sys/class/graphics/fb" .. i .. "/virtual_size") or "640,480"
      local w, h = size:match("(%d+),(%d+)")
      local stride = tonumber(U.trim(U.read("/sys/class/graphics/fb" .. i .. "/stride") or ""))
      return dev, tonumber(w) or 640, tonumber(h) or 480, stride
    end
  end
end

-- rgb hex ("ff8800") -> 2-byte pixel
function M.rgb(hex)
  local r, g, b = tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
  local v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
  return string.char(v & 0xff, v >> 8)
end

-- the Shulker palette
M.C = {
  bg = M.rgb("120a1c"), panel = M.rgb("21152f"), edge = M.rgb("4a2f6b"), accent = M.rgb("a05ad8"),
  text = M.rgb("e8e0f0"), dim = M.rgb("8a7a9a"), ok = M.rgb("3ccf6e"), warn = M.rgb("f0b400"),
  err = M.rgb("f04848"), cyan = M.rgb("40c8e0"), black = M.rgb("000000"),
}

function M.open(dev)
  local d, w, h, stride = M.find()
  dev = dev or d
  if not dev then return nil, "no projector framebuffer (/dev/fb0). Connect a projector to the computer's bus." end
  local f, err = io.open(dev, "r+b")
  if not f then return nil, err end
  local o = { f = f, w = w or 640, h = h or 480 }
  o.stride = stride or o.w * 2
  return setmetatable(o, { __index = M })
end

function M:close() self.f:close() end
function M:flush() self.f:flush() end

function M:fill(x, y, w, h, col)
  if x < 0 then w = w + x x = 0 end
  if y < 0 then h = h + y y = 0 end
  if x + w > self.w then w = self.w - x end
  if y + h > self.h then h = self.h - y end
  if w <= 0 or h <= 0 then return end
  local row = col:rep(w)
  for yy = y, y + h - 1 do
    self.f:seek("set", yy * self.stride + x * 2)
    self.f:write(row)
  end
end

function M:clear(col) self:fill(0, 0, self.w, self.h, col or M.C.bg) end

function M:rect(x, y, w, h, col, t)
  t = t or 1
  self:fill(x, y, w, t, col) self:fill(x, y + h - t, w, t, col)
  self:fill(x, y, t, h, col) self:fill(x + w - t, y, t, h, col)
end

-- cache: (byte, fg, bg, scale) -> pixel run
local runs = {}
local function run(byte, fg, bg, scale)
  local key = fg .. bg .. scale
  local t = runs[key]
  if not t then t = {} runs[key] = t end
  local s = t[byte]
  if not s then
    local px = {}
    for b = 7, 0, -1 do
      local p = (byte >> b) & 1 == 1 and fg or bg
      for _ = 1, scale do px[#px + 1] = p end
    end
    s = table.concat(px)
    t[byte] = s
  end
  return s
end

-- text at pixel x, y; returns the x after it. scale 1 = 8x16 cells
function M:text(x, y, str, fg, bg, scale)
  scale = scale or 1
  fg, bg = fg or M.C.text, bg or M.C.bg
  local cw = 8 * scale
  local maxChars = math.floor((self.w - x) / cw)
  if maxChars <= 0 then return x end
  str = tostring(str):sub(1, maxChars)
  local glyphs = {}
  for i = 1, #str do
    local b = str:byte(i)
    glyphs[i] = font[b] or font[63]
  end
  for row = 0, 15 do
    local parts = {}
    for i, g in ipairs(glyphs) do
      parts[i] = run(tonumber(g:sub(row * 2 + 1, row * 2 + 2), 16), fg, bg, scale)
    end
    local line = table.concat(parts)
    for sy = 0, scale - 1 do
      local yy = y + row * scale + sy
      if yy >= 0 and yy < self.h then
        self.f:seek("set", yy * self.stride + x * 2)
        self.f:write(line)
      end
    end
  end
  return x + #str * cw
end

-- a bar: frac 0..1
function M:bar(x, y, w, h, frac, col, back)
  frac = math.max(0, math.min(1, frac or 0))
  local fw = math.floor((w - 2) * frac + 0.5)
  self:rect(x, y, w, h, M.C.edge)
  self:fill(x + 1, y + 1, fw, h - 2, col)
  self:fill(x + 1 + fw, y + 1, w - 2 - fw, h - 2, back or M.C.bg)
end

-- a titled panel; returns the inner x, y, w, h
function M:panel(x, y, w, h, title)
  self:fill(x, y, w, h, M.C.panel)
  self:rect(x, y, w, h, M.C.edge)
  self:fill(x + 1, y + 1, w - 2, 20, M.C.edge)
  self:text(x + 8, y + 3, title, M.C.text, M.C.edge)
  return x + 8, y + 28, w - 16, h - 34
end

return M
