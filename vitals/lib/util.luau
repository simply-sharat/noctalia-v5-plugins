--!nonstrict
-- Small shared helpers for the Vitals plugin.

local M = {}

--- Trim leading and trailing whitespace.
--- @param text string
--- @return string
function M.trim(text)
  return string.gsub(text or "", "^%s*(.-)%s*$", "%1")
end

--- Split a string into non-empty lines (handles \n and \r\n).
--- @param text string
--- @return string[]
function M.lines(text)
  local out = {}
  if type(text) ~= "string" then
    return out
  end
  for line in text:gmatch("[^\r\n]+") do
    table.insert(out, line)
  end
  return out
end

--- Sanitize a sensor label into a stable lowercase key.
--- @param text string
--- @return string
function M.sanitizeKey(text)
  local s = string.lower(text or "")
  s = string.gsub(s, "[^%w]+", "_")
  s = string.gsub(s, "^_+", "")
  s = string.gsub(s, "_+$", "")
  return s
end

--- Clamp a number into [min, max].
function M.clamp(value, min, max)
  if value < min then
    return min
  end
  if value > max then
    return max
  end
  return value
end

return M
