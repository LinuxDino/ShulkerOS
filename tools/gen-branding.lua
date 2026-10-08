-- Regenerates src/share/issue (shown before login) and src/share/banner (shown at boot) from the
-- logo in src/lib/shulker/art.lua.   lua5.4 tools/gen-branding.lua
package.path = "src/lib/?.lua;" .. package.path
local art = require("shulker.art")
local codes = { accent = "35", soft = "95", text = "97", dim = "90", bold = "1" }
local function c(role, s) return "\27[" .. codes[role] .. "m" .. s .. "\27[0m" end

local issue = art.beside({
  "",
  c("bold", "Shulker OS") .. " on Sedna Linux \\r (\\m)",
  "\\n on \\l",
  "",
  "log in as " .. c("soft", "root") .. " (no password until you set one with passwd)",
}, c)
local f = assert(io.open("src/share/issue", "w"))
f:write("\n" .. table.concat(issue, "\n") .. "\n\n")
f:close()

local banner = art.beside({ "", c("bold", "Shulker OS") .. " %s", c("dim", "booting Sedna Linux"), "",
  "then: " .. c("soft", "man intro") }, c)
f = assert(io.open("src/share/banner", "w"))
f:write(table.concat(banner, "\n") .. "\n")
f:close()
print("wrote src/share/issue and src/share/banner")
