--- The shape of every BlockOS network message, and how to check one.
--
-- All protocols share one envelope, so receivers never hand-parse:
--
--   request   { v = 1, kind = "request", id, op, args, token?, computer_token? }
--   response  { v = 1, kind = "response", reply_to, ok, result | error }
--   event     { v = 1, kind = "event", topic, data }       one-way (announces, alerts)
--
-- Each protocol describes its own payload once, as a schema:
--
--   local ANNOUNCE = {
--     hostname = { type = "string", max = 32 },
--     info = { type = "table", optional = true },
--   }
--
-- and receivers call wire.parse(message, "event", ANNOUNCE). Unknown fields are
-- ignored. Versions: a minor step (1.1) only adds fields, so everyone reads it; a new
-- major still reads older majors (rolling upgrades), while older computers drop
-- messages of a newer major.
-- @module wire

local wire = {}

wire.VERSION = 1

local KINDS = { request = true, response = true, event = true }

local ENVELOPES = {
  request = { id = { type = "string" }, op = { type = "string" } },
  response = { reply_to = { type = "string" }, ok = { type = "boolean" } },
  event = { topic = { type = "string" }, data = { type = "table", optional = true } },
}

-- Check one value against one field rule. Returns nil when fine, else a message.
local function check_field(name, value, rule)
  if type(rule) == "string" then
    rule = { type = rule }
  end
  if value == nil then
    if rule.optional then
      return nil
    end
    return name .. " is missing"
  end
  if rule.type ~= "any" and type(value) ~= rule.type then
    return string.format("%s should be a %s, not a %s", name, rule.type, type(value))
  end
  if rule.max and (type(value) == "string" or type(value) == "table") and #value > rule.max then
    return string.format("%s is longer than %d", name, rule.max)
  end
  if rule.min and type(value) == "number" and value < rule.min then
    return string.format("%s is below %d", name, rule.min)
  end
  if rule.one_of then
    for _, allowed in ipairs(rule.one_of) do
      if value == allowed then
        return nil
      end
    end
    return name .. " has an unknown value"
  end
  return nil
end

--- Check a table against a schema.
--
-- A schema maps field names to a type name ("string", "number", "boolean",
-- "table", "any") or a rule { type, optional, max, min, one_of }.
-- @param value
-- @tparam table schema
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string what is wrong
function wire.validate(value, schema)
  if type(value) ~= "table" then
    return nil, "expected a table"
  end
  for name, rule in pairs(schema) do
    local problem = check_field(name, value[name], rule)
    if problem then
      return nil, problem
    end
  end
  return true
end

--- Check a received message: envelope, kind and (optionally) its payload.
-- For events the payload is `data`; for requests it is `args`; for responses
-- it is `result` (only when ok).
-- @param message
-- @tparam string kind "request", "response" or "event"
-- @tparam[opt] table schema Payload schema.
-- @treturn[1] table The message.
-- @treturn[2] nil
-- @treturn[2] string what is wrong
function wire.parse(message, kind, schema)
  if type(message) ~= "table" then
    return nil, "not a BlockOS message"
  end
  if type(message.v) ~= "number" or math.floor(message.v) > wire.VERSION or message.v < 1 then
    return nil, "unsupported wire version"
  end
  if message.kind ~= kind or not KINDS[kind] then
    return nil, "expected a " .. kind
  end
  local ok, problem = wire.validate(message, ENVELOPES[kind])
  if not ok then
    return nil, problem
  end
  if schema then
    local payload = message.data or {}
    if kind == "request" then
      payload = message.args or {}
    elseif kind == "response" then
      payload = message.ok and message.result or nil
    end
    ok, problem = wire.validate(payload, schema)
    if not ok then
      return nil, problem
    end
  end
  return message
end

--- Build a one-way event.
-- @tparam string topic e.g. "announce", "stock_alert"
-- @tparam[opt] table data
-- @treturn table
function wire.event(topic, data)
  return { v = wire.VERSION, kind = "event", topic = topic, data = data }
end

--- Build a request.
-- @tparam string id
-- @tparam string op
-- @param args
-- @tparam[opt] string token
-- @tparam[opt] string computer_token
-- @treturn table
function wire.request(id, op, args, token, computer_token)
  return {
    v = wire.VERSION,
    kind = "request",
    id = id,
    op = op,
    args = args,
    token = token,
    computer_token = computer_token,
  }
end

--- Build a response.
-- @tparam string reply_to Request id.
-- @tparam boolean ok
-- @param value Result when ok, error message otherwise.
-- @treturn table
function wire.response(reply_to, ok, value)
  local response = { v = wire.VERSION, kind = "response", reply_to = reply_to, ok = ok }
  if ok then
    response.result = value
  else
    response.error = value
  end
  return response
end

return wire
