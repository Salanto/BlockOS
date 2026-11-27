--- Logistics for programs: ask for items from a turtle, a pocket computer or any
-- script, e.g. a mining turtle refuelling at the nearest depot.
--
--   local logistics_api = import("logistics_api")
--   local result, err = logistics_api.request("minecraft:coal", 16, { here = true })
--   -- result = { moved, item, label, output, output_label, pos, node }
--   -- then drive to result.pos and suck the items out
--
-- A depot is an output chest with a position (`logistics storage pos`). A lost answer
-- is retried safely: rpc runs each request once, so nothing is delivered twice. Works
-- against the controller or a lone node (on that node itself). Without a domain login the call counts as the
-- computer's (allowed while logistics-users includes everyone, the default).
-- @module logistics_api

local logistics_client = import("logistics_client")

local logistics_api = {}

--- Where this computer is (GPS); tests replace it.
logistics_api.locate = function()
  local x, y, z = gps.locate(2)
  if not x then
    return nil
  end
  return { x = x, y = y, z = z }
end

local function connect(options)
  return logistics_client.connect(options and options.server)
end

local function where(options)
  if options.near then
    return options.near
  end
  if options.here then
    local pos = logistics_api.locate()
    if not pos then
      return nil, "no GPS fix: are GPS hosts in range of a wireless modem?"
    end
    return pos
  end
  return nil
end

--- Request items.
-- @tparam string item Item id or (part of) its name.
-- @tparam number count
-- @tparam[opt] table options { output = name } | { near = { x, y, z } } |
--   { here = true } (the nearest depot to this computer), plus server = name
-- @treturn[1] table { moved, item, label, output, output_label?, pos?, node }
-- @treturn[2] nil
-- @treturn[2] string error message
function logistics_api.request(item, count, options)
  options = options or {}
  local near, err = where(options)
  if err then
    return nil, err
  end
  local connection, connect_error = connect(options)
  if not connection then
    return nil, connect_error
  end
  return connection.call("request", {
    item = item,
    count = count,
    output = options.output,
    near = near,
  })
end

--- The depots (output chests with a position), nearest first when a place is given.
-- @tparam[opt] table options { near = { x, y, z } } | { here = true }, plus server
-- @treturn[1] {table...} { node, handle, label, pos, distance? }
-- @treturn[2] nil
-- @treturn[2] string error message
function logistics_api.depots(options)
  options = options or {}
  local near, err = where(options)
  if err then
    return nil, err
  end
  local connection, connect_error = connect(options)
  if not connection then
    return nil, connect_error
  end
  return connection.call("depots", { near = near })
end

--- How many of an item there are (0 when none).
-- @tparam string item Item id.
-- @tparam[opt] table options { server = name }
-- @treturn[1] number
-- @treturn[2] nil
-- @treturn[2] string error message
function logistics_api.count(item, options)
  local connection, connect_error = connect(options)
  if not connection then
    return nil, connect_error
  end
  local catalog, err = connection.call("catalog")
  if not catalog then
    return nil, err
  end
  for _, row in ipairs(catalog) do
    if row.item == item then
      return row.count
    end
  end
  return 0
end

return logistics_api
