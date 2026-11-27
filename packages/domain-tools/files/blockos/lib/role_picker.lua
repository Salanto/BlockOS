--- Computer roles by ticking lists (dsa): which packages a role holds, chosen from
-- what the package source offers, and which computers have it, chosen from the
-- domain's computers. Nothing to type but a role's name.
-- @module role_picker

local role_picker = {}

--- Kinds left out of the package list: they come along as dependencies (and core and
-- net are on every computer anyway).
role_picker.HIDDEN_KINDS = { base = true, protocol = true, library = true }

--- Where packages and the screen come from (tests replace these).
role_picker.env = {
  -- The index of the source pkg installs from: a package server if one is found,
  -- else the latest GitHub release.
  index = function()
    local found, pkg_remote = pcall(import, "pkg_remote")
    if found then
      local id, label = pkg_remote.find_server()
      if id then
        return pkg_remote.source(id, label).index()
      end
    end
    return import("pkg").github_source().index()
  end,
  installed = function() return import("pkg").installed() end,
  checklist = function(spec) return import("ui").checklist(spec) end,
}

local function sorted_keys(map)
  local keys = {}
  for key in pairs(map) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

local function set_of(list)
  local set = {}
  for _, value in ipairs(list or {}) do
    set[value] = true
  end
  return set
end

--- The packages worth choosing, as checklist items.
-- @tparam table packages [name] = { optional, exclusive?, kind?, description? } (an index)
-- @tparam {string...} current The role's packages now (always listed, so none is lost).
-- @treturn {table...} items { label, detail, is_checked, name }
function role_picker.package_items(packages, current)
  local chosen = set_of(current)
  local items = {}
  for _, name in ipairs(sorted_keys(packages)) do
    local entry = packages[name]
    local is_offered = entry.optional and not entry.exclusive
      and not role_picker.HIDDEN_KINDS[entry.kind or ""]
    if is_offered or chosen[name] then
      local detail = entry.description or entry.kind
      items[#items + 1] = { label = name, detail = detail, is_checked = chosen[name], name = name }
    end
  end
  -- A role may name a package the source no longer has: keep it visible.
  for _, name in ipairs(current or {}) do
    if not packages[name] then
      items[#items + 1] = { label = name, detail = "(not in the package source)",
        is_checked = true, name = name }
    end
  end
  return items
end

--- Names of the ticked items.
-- @tparam {table...} items With `name`.
-- @tparam table checked From ui.checklist.
-- @treturn {string...}
function role_picker.ticked(items, checked)
  local names = {}
  for index, item in ipairs(items) do
    if checked[index] then
      names[#names + 1] = item.name
    end
  end
  return names
end

--- Let the user tick a role's packages.
-- @tparam string role_name
-- @tparam[opt] {string...} current Its packages now.
-- @treturn[1] {string...} The chosen packages.
-- @treturn[2] nil Cancelled.
-- @treturn[2] string|nil why the list may be short (no package source answered)
function role_picker.pick_packages(role_name, current)
  local index, err = role_picker.env.index()
  local packages = index and index.packages
  local note = nil
  if type(packages) ~= "table" then
    -- No source answered: offer what this computer has installed instead.
    packages = role_picker.env.installed()
    note = "No package source answered (" .. tostring(err) .. "): showing this computer's"
      .. " packages."
  end
  local items = role_picker.package_items(packages, current)
  local checked = role_picker.env.checklist({
    title = "Packages of " .. role_name,
    text = note or "Tick what computers with this role should have. Dependencies come"
      .. " along by themselves.",
    items = items,
  })
  if not checked then
    return nil
  end
  return role_picker.ticked(items, checked)
end

local function describe_host(host)
  local parts = { host.kind or "?" }
  if host.seen then
    parts[#parts + 1] = host.seen
  end
  if #(host.roles or {}) > 0 then
    parts[#parts + 1] = "[" .. table.concat(host.roles, ",") .. "]"
  end
  return table.concat(parts, "  ")
end

--- The computers as checklist items, ticked where they have the role.
-- @tparam string role_name
-- @tparam {table...} hosts From list_computers ({ hostname, kind, roles, seen? }).
-- @treturn {table...} items
function role_picker.computer_items(role_name, hosts)
  local items = {}
  for _, host in ipairs(hosts) do
    items[#items + 1] = {
      label = host.hostname,
      detail = describe_host(host),
      is_checked = set_of(host.roles)[role_name],
      host = host,
    }
  end
  return items
end

--- What to assign after ticking computers: only the computers whose roles change.
-- @tparam string role_name
-- @tparam {table...} items From computer_items.
-- @tparam table checked From ui.checklist.
-- @treturn {table...} { hostname, roles } for computer_assign
function role_picker.computer_changes(role_name, items, checked)
  local changes = {}
  for index, item in ipairs(items) do
    local wants = checked[index] == true
    local has = item.is_checked == true
    if wants ~= has then
      local roles = {}
      for _, role in ipairs(item.host.roles or {}) do
        if role ~= role_name then
          roles[#roles + 1] = role
        end
      end
      if wants then
        roles[#roles + 1] = role_name
      end
      changes[#changes + 1] = { hostname = item.host.hostname, roles = roles }
    end
  end
  return changes
end

--- Let the user tick the computers that have a role.
-- @tparam string role_name
-- @tparam {table...} hosts From list_computers.
-- @treturn[1] {table...} changes for computer_assign (see computer_changes)
-- @treturn[2] nil Cancelled.
function role_picker.pick_computers(role_name, hosts)
  local items = role_picker.computer_items(role_name, hosts)
  local checked = role_picker.env.checklist({
    title = "Computers with " .. role_name,
    text = "Tick the computers that get this role. They install its packages by"
      .. " themselves (within 30 minutes, or update them now).",
    items = items,
  })
  if not checked then
    return nil
  end
  return role_picker.computer_changes(role_name, items, checked)
end

--- Let the user tick a computer's roles.
-- @tparam table host From list_computers.
-- @tparam {table...} roles From list_computer_roles ({ name, packages }).
-- @treturn[1] {string...} The chosen roles.
-- @treturn[2] nil Cancelled.
function role_picker.pick_roles(host, roles)
  local has = set_of(host.roles)
  local items = {}
  for _, role in ipairs(roles) do
    items[#items + 1] = {
      label = role.name,
      detail = table.concat(role.packages or {}, " "),
      is_checked = has[role.name],
      name = role.name,
    }
  end
  local checked = role_picker.env.checklist({
    title = "Roles of " .. host.hostname,
    text = #items == 0 and "No computer roles yet: add them in the Roles tab." or
      "Tick the roles this computer should have.",
    items = items,
  })
  if not checked then
    return nil
  end
  return role_picker.ticked(items, checked)
end

return role_picker
