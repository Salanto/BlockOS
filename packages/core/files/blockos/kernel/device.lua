--- The one place that knows what kind of device BlockOS is running on.
--
-- Never detect the device type anywhere else (for example from `multishell` or
-- `colours`): all device differences go through this module and `ui`.
-- @module device

local device = {}

local detected = nil

local function detect()
  local kind = "computer"
  if turtle then
    kind = "turtle"
  elseif pocket then
    kind = "pocket"
  elseif commands then
    kind = "command"
  end
  detected = { kind = kind, is_advanced = term.isColour() }
  return detected
end

--- @treturn string "computer", "turtle", "pocket" or "command".
function device.kind()
  return (detected or detect()).kind
end

--- @treturn boolean True on advanced (colour) devices.
function device.is_advanced()
  return (detected or detect()).is_advanced
end

--- Forget the detection result (tests call this after stubbing globals).
function device.reset()
  detected = nil
end

return device
