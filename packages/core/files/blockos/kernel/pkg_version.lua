--- Package versions: parsing, comparing and ranges.
-- (pkg offers these functions too.)
-- @module pkg_version


local pkg_version = {}

------------------------------------------------------------------------------
-- Versions
------------------------------------------------------------------------------

-- "v1.2.3-rc1" -> { 1, 2, 3 }, "rc1"
local function parse_version(version)
  local text = tostring(version):gsub("^v", "")
  local numbers_part, prerelease = text:match("^([%d%.]+)%-?(.*)$")
  if not numbers_part then
    return nil
  end
  local numbers = {}
  for number in numbers_part:gmatch("%d+") do
    numbers[#numbers + 1] = tonumber(number)
  end
  return numbers, prerelease
end

--- Compare two versions. A release sorts after its prereleases (0.1.0 > 0.1.0-rc1).
-- @tparam string a
-- @tparam string b
-- @treturn number -1, 0 or 1
function pkg_version.compare_versions(a, b)
  local numbers_a, pre_a = parse_version(a)
  local numbers_b, pre_b = parse_version(b)
  if not numbers_a or not numbers_b then
    if a == b then
      return 0
    end
    return tostring(a) < tostring(b) and -1 or 1
  end

  for i = 1, math.max(#numbers_a, #numbers_b) do
    local x = numbers_a[i] or 0
    local y = numbers_b[i] or 0
    if x ~= y then
      return x < y and -1 or 1
    end
  end

  if pre_a == pre_b then
    return 0
  elseif pre_a == "" then
    return 1
  elseif pre_b == "" then
    return -1
  end
  return pre_a < pre_b and -1 or 1
end

--- Check a version against a range.
-- @tparam string version
-- @tparam string range "*", "0.1.0", ">=0.1", ">0.1", "<=1.0", "<1.0" or "=0.2".
-- @treturn boolean
function pkg_version.satisfies(version, range)
  if range == nil or range == "*" or range == "" then
    return true
  end
  local operator, wanted = tostring(range):match("^%s*([<>=]*)%s*(.-)%s*$")
  local order = pkg_version.compare_versions(version, wanted)
  if operator == ">=" then
    return order >= 0
  elseif operator == ">" then
    return order > 0
  elseif operator == "<=" then
    return order <= 0
  elseif operator == "<" then
    return order < 0
  end
  return order == 0
end

return pkg_version
