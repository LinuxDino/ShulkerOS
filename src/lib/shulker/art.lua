-- The Shulker OS logo, drawn with DEC special graphics (ESC ( 0), which OC2's terminal font has:
-- box lines, the checkerboard and the diamond. Unicode block characters would show as "?" there.
local M = {}

local G, A = "\27(0", "\27(B"

-- lines of the logo; color(role, text) colours a part (pass nil for no colour)
-- ascii = true: plain ASCII for terminals without DEC graphics (or when colours are off)
function M.logo(color, ascii)
  local c = color or function(_, s) return s end
  if ascii then
    return { "+---------+", "|#########|", "+---------+", "|  o   o  |", "|    -    |", "+---------+" }
  end
  local function g(role, s) return c(role, G .. s .. A) end
  return {
    g("accent", "lqqqqqqqqqk"),
    g("accent", "x") .. g("soft", "aaaaaaaaa") .. g("accent", "x"),
    g("accent", "tqqqqqqqqqu"),
    g("accent", "x") .. "  " .. g("text", "`") .. "   " .. g("text", "`") .. "  " .. g("accent", "x"),
    g("accent", "x") .. "    " .. c("soft", "-") .. "    " .. g("accent", "x"),
    g("accent", "mqqqqqqqqqj"),
  }
end
M.WIDTH = 11

-- the logo with text lines beside it
function M.beside(lines, color, gap, ascii)
  local logo = M.logo(color, ascii)
  local out = {}
  gap = gap or "   "
  for i = 1, math.max(#logo, #lines) do
    out[#out + 1] = "  " .. (logo[i] or string.rep(" ", M.WIDTH)) .. gap .. (lines[i] or "")
  end
  return out
end

return M
