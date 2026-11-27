--- Crafting recipes of a logistics node: a sequence of steps run against machines on
-- the node's storage network (blocks with the role "machine": Create basins, depots,
-- presses' input chests, ...).
--
-- A recipe (kept in /etc/blockos/logistics-recipes, by result item):
--   { item, makes = 1, retries = 3, scrap = { item... }, steps = {
--       { kind = "supply", item, count, to },              -- storage -> machine block
--       { kind = "wait", item, count, at, timeout },       -- until it shows up there
--       { kind = "retrieve", from },                       -- that block -> storage
--   } }
-- An attempt fails when a wait times out or one of the recipe's scrap items turns up
-- where the result is awaited (Create's sequenced assembly can fail into scrap; its
-- in-between items are fine). The machine blocks are then emptied into storage and the steps
-- start again, up to `retries` times.
--
-- Pure functions over plain tables (tested without hardware).
-- @module logistics_recipes

local logistics_recipes = {}

logistics_recipes.KINDS = { supply = true, wait = true, retrieve = true }
logistics_recipes.DEFAULT_RETRIES = 3
logistics_recipes.DEFAULT_TIMEOUT = 30
logistics_recipes.MIN_TIMEOUT = 5
logistics_recipes.MAX_STEPS = 16

local ITEM_PATTERN = "^[%w_%-%.]+:[%w_%-%./]+$"

local function is_item(text)
  return type(text) == "string" and text:match(ITEM_PATTERN) ~= nil
end

local function is_block(text)
  return type(text) == "string" and text ~= "" and #text <= 64
end

local function positive(number)
  number = tonumber(number)
  return number and number >= 1 and math.floor(number) or nil
end

--- Check one step and clean it.
-- @treturn[1] table
-- @treturn[2] nil
-- @treturn[2] string error message
function logistics_recipes.clean_step(step)
  if type(step) ~= "table" or not logistics_recipes.KINDS[step.kind] then
    return nil, "a step is supply, wait or retrieve"
  end
  if step.kind == "supply" then
    if not (is_item(step.item) and positive(step.count) and is_block(step.to)) then
      return nil, "supply needs an item id, a count and a machine"
    end
    return { kind = "supply", item = step.item, count = positive(step.count), to = step.to }
  elseif step.kind == "wait" then
    if not (is_item(step.item) and positive(step.count) and is_block(step.at)) then
      return nil, "wait needs an item id, a count and the block it appears in"
    end
    local timeout = math.max(logistics_recipes.MIN_TIMEOUT,
      positive(step.timeout) or logistics_recipes.DEFAULT_TIMEOUT)
    return { kind = "wait", item = step.item, count = positive(step.count), at = step.at,
      timeout = timeout }
  end
  if not is_block(step.from) then
    return nil, "retrieve needs the block to empty"
  end
  return { kind = "retrieve", from = step.from }
end

--- Check a whole recipe and clean it.
-- @treturn[1] table
-- @treturn[2] nil
-- @treturn[2] string error message
function logistics_recipes.clean(recipe)
  if type(recipe) ~= "table" or not is_item(recipe.item) then
    return nil, "a recipe needs the item id it makes"
  end
  local steps = {}
  local has_wait = false
  for index, step in ipairs(recipe.steps or {}) do
    local clean, err = logistics_recipes.clean_step(step)
    if not clean then
      return nil, "step " .. index .. ": " .. err
    end
    has_wait = has_wait or clean.kind == "wait"
    steps[#steps + 1] = clean
  end
  if #steps > logistics_recipes.MAX_STEPS then
    return nil, "at most " .. logistics_recipes.MAX_STEPS .. " steps"
  end
  local scrap = {}
  for _, item in ipairs(recipe.scrap or {}) do
    if not is_item(item) then
      return nil, "scrap items are item ids: " .. tostring(item)
    end
    scrap[#scrap + 1] = item
  end
  return {
    item = recipe.item,
    makes = positive(recipe.makes) or 1,
    retries = math.max(0,
      math.floor(tonumber(recipe.retries) or logistics_recipes.DEFAULT_RETRIES)),
    scrap = scrap,
    steps = steps,
    is_ready = has_wait and #steps > 0 or nil,
  }
end

--- An empty recipe to add steps to by hand.
function logistics_recipes.new(item)
  return { item = item, makes = 1, retries = logistics_recipes.DEFAULT_RETRIES, scrap = {},
    steps = {} }
end

--- Every block a recipe uses (emptied after a failed attempt).
-- @treturn {string...}
function logistics_recipes.blocks(recipe)
  local seen, blocks = {}, {}
  for _, step in ipairs(recipe.steps) do
    local block = step.to or step.at or step.from
    if block and not seen[block] then
      seen[block] = true
      blocks[#blocks + 1] = block
    end
  end
  return blocks
end

--- Ingredients one run needs: [item] = count.
function logistics_recipes.ingredients(recipe)
  local needs = {}
  for _, step in ipairs(recipe.steps) do
    if step.kind == "supply" then
      needs[step.item] = (needs[step.item] or 0) + step.count
    end
  end
  return needs
end

--- Does a block's content mean the attempt failed? Only the recipe's scrap items
-- count: machines hold in-between items while they work.
-- @tparam table recipe
-- @tparam table contents [item] = count, of the block the result is awaited in
-- @treturn string|nil the scrap item found
function logistics_recipes.failed_item(recipe, contents)
  for _, item in ipairs(recipe.scrap) do
    if (contents[item] or 0) > 0 then
      return item
    end
  end
  return nil
end

--- How many runs make at least `count` items.
function logistics_recipes.runs_for(recipe, count)
  return math.max(1, math.ceil(count / math.max(1, recipe.makes)))
end

------------------------------------------------------------------------------
-- Teaching: a draft recipe from what a player did at the machines
------------------------------------------------------------------------------

--- Turn observations into a draft recipe.
-- @tparam string item The result.
-- @tparam table seen
--   supplies  [block] = { [item] = most seen added at once }
--   result    { block, count, seconds } where the result first appeared, or nil
-- @treturn[1] table recipe (cleaned)
-- @treturn[2] nil
-- @treturn[2] string error message
function logistics_recipes.draft(item, seen)
  if not seen.result then
    return nil, "the result never showed up in a machine; nothing to learn"
  end
  local steps = {}
  local blocks = {}
  for block in pairs(seen.supplies or {}) do
    blocks[#blocks + 1] = block
  end
  table.sort(blocks)
  for _, block in ipairs(blocks) do
    local items = {}
    for ingredient in pairs(seen.supplies[block]) do
      if ingredient ~= item then
        items[#items + 1] = ingredient
      end
    end
    table.sort(items)
    for _, ingredient in ipairs(items) do
      steps[#steps + 1] = { kind = "supply", item = ingredient,
        count = seen.supplies[block][ingredient], to = block }
    end
  end
  if #steps == 0 then
    return nil, "no ingredients went into a machine; nothing to learn"
  end
  local result = seen.result
  -- Room for a slow machine: three times as long as it took, at least the minimum.
  local timeout = math.max(logistics_recipes.MIN_TIMEOUT, math.ceil(result.seconds * 3))
  steps[#steps + 1] = { kind = "wait", item = item, count = result.count, at = result.block,
    timeout = timeout }
  steps[#steps + 1] = { kind = "retrieve", from = result.block }
  return logistics_recipes.clean({ item = item, makes = result.count, steps = steps })
end

--- One line per step, for people.
function logistics_recipes.describe_step(step)
  if step.kind == "supply" then
    return string.format("supply %d %s -> %s", step.count, step.item, step.to)
  elseif step.kind == "wait" then
    return string.format("wait for %d %s in %s (%ds)", step.count, step.item, step.at,
      step.timeout)
  end
  return "retrieve everything from " .. step.from
end

return logistics_recipes
