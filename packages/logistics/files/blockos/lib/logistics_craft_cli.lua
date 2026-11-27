--- `logistics craft ...`: crafting from the command line.
--
-- From any computer (through the hub):
--   logistics craft                         what can be crafted, and the jobs
--   logistics craft <item> [count]          start a job on the node with the recipe
-- On a node with logistics-crafting (recipes live there, next to the machines):
--   logistics craft teach <item id>         do the craft once; the node learns it
--   logistics craft recipes | show <item>   the recipes, or one recipe's steps
--   logistics craft new <item id>           an empty recipe to add steps to
--   logistics craft step <item> add supply <ingredient> <count> <machine> [slot]
--   logistics craft step <item> add wait <result> <count> <block> [timeout]
--   logistics craft step <item> add retrieve <block>
--   logistics craft step <item> del <n>
--   logistics craft set <item> retries <n> | makes <n> | scrap <item...>
--   logistics craft set <item> machine <block> <@group[:n]>   use a group instead
--   logistics craft group <name> <block[,block...]>...       stations of a group
--   logistics craft group <name> | groups | group-del <name>
--   logistics craft forget <item> | cancel <item>
-- A machine group lists interchangeable stations (one block each, or several in the
-- same order, e.g. a depot and its output chest); each run takes a free station.
-- @module logistics_craft_cli

local logistics = import("logistics")
local ui = import("ui")

local logistics_craft_cli = {}

local LOCAL_COMMANDS = {
  teach = true, recipes = true, show = true, new = true, step = true, set = true,
  forget = true, cancel = true, group = true, groups = true, ["group-del"] = true,
}

local function fail(message)
  ui.print(tostring(message), "error")
end

local function usage()
  print("Usage: logistics craft [<item> [count]]")
  print("       logistics craft teach <item id> | recipes | show <item>")
  print("       logistics craft new <item id> | forget <item> | cancel <item>")
  print("       logistics craft step <item> add supply <ingredient> <count> <machine> [slot]")
  print("       logistics craft step <item> add wait <result> <count> <block> [timeout]")
  print("       logistics craft step <item> add retrieve <block> | del <n>")
  print("       logistics craft set <item> retries <n> | makes <n> | scrap <item...>")
  print("       logistics craft set <item> machine <block> <@group[:n]>")
  print("       logistics craft group <name> <block[,block...]>... | groups")
  print("       logistics craft group-del <name>")
end

------------------------------------------------------------------------------
-- Through the hub
------------------------------------------------------------------------------

local function describe_job(job)
  local text = string.format("%-10s %-22s %d/%d %s", ui.fit(job.node or "", 10),
    ui.fit(job.item, 22), job.made or 0, job.count or 0, job.state)
  if job.note then
    text = text .. " (" .. job.note .. ")"
  end
  return text
end

local function job_role(job)
  if job.state == "failed" then
    return "error"
  elseif job.state == "waiting" then
    return "warn"
  elseif job.state == "done" or job.state == "cancelled" then
    return "dim"
  end
  return "text"
end

local function overview(connection)
  local recipes, err = connection.call("recipes")
  if not recipes then
    return fail(err)
  end
  ui.title("Crafting (" .. connection.describe .. ")")
  if #recipes == 0 then
    ui.print("No recipes yet: on a node with logistics-crafting, 'logistics craft teach <item>'.",
      "dim")
  end
  ui.table({
    { title = "ITEM", key = "label" },
    { title = "STORED", key = "count" },
    { title = "NODE", key = "node" },
  }, recipes)
  local jobs = connection.call("jobs") or {}
  if #jobs > 0 then
    ui.title("Jobs")
    for _, job in ipairs(jobs) do
      ui.print(describe_job(job), job_role(job))
    end
  end
end

local function start(connection, item, count_text)
  local count = tonumber(count_text) or 1
  local result, err = connection.call("craft", { item = item, count = count })
  if not result then
    return fail(err)
  end
  ui.print(string.format("Crafting %d %s on %s.", result.count or count,
    tostring(result.label or item), tostring(result.node)), "ok")
end

------------------------------------------------------------------------------
-- On the node
------------------------------------------------------------------------------

local function crafter_here()
  local crafter = blockos and blockos.logistics_crafter
  if not crafter then
    return nil, "Run this on a logistics node with logistics-crafting installed."
  end
  return crafter
end

-- A machine or block by name or label, on this node; "@group" and "@group:n" pass.
local function block_named(query)
  if tostring(query):match("^@[%w_%-]+:?%d*$") then
    return query
  end
  local node = blockos.logistics_node
  local handles = {}
  for _, row in ipairs(node.list_storages()) do
    handles[#handles + 1] = row.handle
  end
  return logistics.find_storage(node.config, handles, query)
end

local function show_recipe(recipe)
  local recipes = import("logistics_recipes")
  ui.title("Recipe: " .. recipe.item)
  ui.field("Makes", tostring(recipe.makes), nil, 8)
  ui.field("Retries", tostring(recipe.retries), nil, 8)
  ui.field("Scrap", #recipe.scrap > 0 and table.concat(recipe.scrap, ", ") or "-", nil, 8)
  for index, step in ipairs(recipe.steps) do
    ui.print(string.format("%2d %s", index, recipes.describe_step(step)))
  end
  if not recipe.is_ready then
    ui.print("Not ready: a recipe needs at least one wait step.", "warn")
  end
end

local function list_recipes(crafter)
  ui.title("Recipes on this node")
  local summary = crafter.summary()
  for _, item in ipairs(summary.recipes) do
    ui.print("  " .. item)
  end
  if #summary.recipes == 0 then
    ui.print("  (none)", "faint")
  end
end

-- Watch the machines while the player crafts once.
local function teach(crafter, item)
  if not item or not item:find(":") then
    return fail("Give the full item id, e.g. create:brass_ingot.")
  end
  local machines, err = crafter.teach_start(item)
  if not machines then
    return fail(err)
  end
  local function draw(seen)
    ui.clear()
    ui.title("Teaching " .. item)
    ui.print("Put the ingredients into the machines (" .. #machines .. ") and let them", "dim")
    ui.print("work. When the result is in a machine, press Enter. q cancels.", "dim")
    for block, items in pairs(seen.supplies) do
      for ingredient, count in pairs(items) do
        ui.status(count .. " x " .. ingredient .. " -> " .. block, "text")
      end
    end
    if seen.result then
      ui.status(string.format("%d x %s appeared in %s after %ds", seen.result.count, item,
        seen.result.block, math.floor(seen.result.seconds)), "ok")
    end
  end
  -- Whatever ends this loop (Ctrl+T, a logout, an error), teaching must stop too, or
  -- the node's jobs stay paused.
  local finished, wants_save = pcall(function()
    local timer = os.startTimer(0.5)
    draw(crafter.teach_poll())
    while true do
      local event, value = import("events").pull()
      if event == "timer" and value == timer then
        draw(crafter.teach_poll())
        timer = os.startTimer(0.5)
      elseif event == "key" and value == keys.enter then
        return true
      elseif event == "char" and value == "q" then
        return false
      end
    end
  end)
  if not finished or not wants_save then
    crafter.teach_cancel()
    if not finished then
      error(wants_save, 0)
    end
    return ui.print("Cancelled.", "dim")
  end
  local recipe, finish_error = crafter.teach_finish()
  if not recipe then
    return fail(finish_error)
  end
  show_recipe(recipe)
  ui.print("Saved. Add scrap items or retries with 'logistics craft set'.", "ok")
end

local function parse_step(words)
  local kind = words[5]
  if kind == "supply" then
    local machine, err = block_named(words[8] or "")
    if not machine then
      return nil, err
    end
    return { kind = "supply", item = words[6], count = tonumber(words[7]), to = machine,
      slot = tonumber(words[9]) }
  elseif kind == "wait" then
    local block, err = block_named(words[8] or "")
    if not block then
      return nil, err
    end
    return { kind = "wait", item = words[6], count = tonumber(words[7]), at = block,
      timeout = tonumber(words[9]) }
  elseif kind == "retrieve" then
    local block, err = block_named(words[6] or "")
    if not block then
      return nil, err
    end
    return { kind = "retrieve", from = block }
  end
  return nil, "a step is supply, wait or retrieve"
end

local function copy(recipe)
  local result = {}
  for key, value in pairs(recipe) do
    result[key] = value
  end
  result.steps = {}
  for index, step in ipairs(recipe.steps) do
    result.steps[index] = step
  end
  return result
end

local function save_and_show(crafter, recipe)
  local saved, err = crafter.set_recipe(recipe)
  if not saved then
    return fail(err)
  end
  show_recipe(saved)
end

local function change_steps(crafter, words)
  local recipe = crafter.recipe(words[3] or "")
  if not recipe then
    return fail("No recipe for " .. tostring(words[3]) .. " (logistics craft new <item>).")
  end
  recipe = copy(recipe)
  if words[4] == "add" then
    local step, err = parse_step(words)
    if not step then
      return fail(err)
    end
    recipe.steps[#recipe.steps + 1] = step
  elseif words[4] == "del" and tonumber(words[5]) and recipe.steps[tonumber(words[5])] then
    table.remove(recipe.steps, tonumber(words[5]))
  else
    return usage()
  end
  save_and_show(crafter, recipe)
end

local function change_setting(crafter, words)
  local recipe = crafter.recipe(words[3] or "")
  if not recipe then
    return fail("No recipe for " .. tostring(words[3]) .. ".")
  end
  recipe = copy(recipe)
  local what = words[4]
  if what == "retries" or what == "makes" then
    recipe[what] = tonumber(words[5])
  elseif what == "scrap" then
    recipe.scrap = { table.unpack(words, 5) }
  elseif what == "machine" and words[5] and words[6] then
    -- Swap one block for a group reference in every step (after teaching).
    for index, step in ipairs(recipe.steps) do
      local changed = {}
      for key, value in pairs(step) do
        changed[key] = value
      end
      for _, field in ipairs({ "to", "at", "from" }) do
        if changed[field] == words[5] then
          changed[field] = words[6]
        end
      end
      recipe.steps[index] = changed
    end
  else
    return usage()
  end
  save_and_show(crafter, recipe)
end

local function show_groups(crafter)
  ui.title("Machine groups on this node")
  local names = {}
  for name in pairs(crafter.groups) do
    names[#names + 1] = name
  end
  table.sort(names)
  if #names == 0 then
    ui.print("  (none)", "faint")
  end
  for _, name in ipairs(names) do
    local stations = {}
    for index, station in ipairs(crafter.groups[name]) do
      stations[index] = table.concat(station, "+")
    end
    ui.print("  @" .. name .. ": " .. table.concat(stations, ", "))
  end
end

-- group <name> <block[,block...]>...: each word is a station.
local function set_group(crafter, words)
  local name = words[3]
  if not name then
    return usage()
  end
  if not words[4] then
    return show_groups(crafter)
  end
  local stations = {}
  for index = 4, #words do
    local station = {}
    for query in words[index]:gmatch("[^,]+") do
      local block, err = block_named(query)
      if not block then
        return fail(err)
      end
      station[#station + 1] = block
    end
    stations[#stations + 1] = station
  end
  local ok, err = crafter.set_group(name, stations)
  if not ok then
    return fail(err)
  end
  ui.print("Group @" .. name .. " has " .. #stations .. " station(s).", "ok")
  ui.print("Use it in a recipe: logistics craft set <item> machine <block> @" .. name, "dim")
end

local function run_local(words)
  local crafter, err = crafter_here()
  if not crafter then
    return fail(err)
  end
  local action, item = words[2], words[3]
  if action == "groups" then
    show_groups(crafter)
  elseif action == "group" then
    set_group(crafter, words)
  elseif action == "group-del" then
    local ok, del_error = crafter.set_group(item or "", nil)
    if not ok then
      return fail(del_error)
    end
    ui.print("Group removed.", "ok")
  elseif action == "teach" then
    teach(crafter, item)
  elseif action == "recipes" then
    list_recipes(crafter)
  elseif action == "show" then
    local recipe = crafter.recipe(item or "")
    if not recipe then
      return fail("No recipe for " .. tostring(item) .. ".")
    end
    show_recipe(recipe)
  elseif action == "new" then
    if crafter.recipe(item or "") then
      return fail("There is a recipe for " .. item .. " already.")
    end
    local recipes = import("logistics_recipes")
    local saved, new_error = crafter.set_recipe(recipes.new(item or ""))
    if not saved then
      return fail(new_error)
    end
    ui.print("Empty recipe made; add steps with 'logistics craft step'.", "ok")
  elseif action == "step" then
    change_steps(crafter, words)
  elseif action == "set" then
    change_setting(crafter, words)
  elseif action == "forget" then
    local ok, forget_error = crafter.forget(item or "")
    if not ok then
      return fail(forget_error)
    end
    ui.print("Forgot the recipe for " .. item .. ".", "ok")
  elseif action == "cancel" then
    local ok, cancel_error = crafter.cancel(item or "")
    if not ok then
      return fail(cancel_error)
    end
    ui.print("Cancelled; the machines were emptied into storage.", "ok")
  end
end

--- Run `logistics craft ...`.
-- @tparam {string...} words The command's words (words[1] == "craft").
-- @tparam function connect function() -> connection | nil (prints its own error)
function logistics_craft_cli.run(words, connect)
  local action = words[2]
  if action == "help" then
    return usage()
  end
  if LOCAL_COMMANDS[action] then
    return run_local(words)
  end
  local connection = connect()
  if not connection then
    return
  end
  if action == nil then
    return overview(connection)
  end
  start(connection, action, words[3])
end

return logistics_craft_cli
