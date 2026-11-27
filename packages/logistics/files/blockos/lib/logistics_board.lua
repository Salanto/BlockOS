--- The levels board: watched items drawn on a CC monitor or a Create Display
-- Board (through a Display Link).
--
-- Data shape (from the `status` operation or the local service):
--   { title, updated, rows = { { label, count, limit, is_low }... } }
-- Rows come sorted with low items first.
-- @module logistics_board

local ui = import("ui")

local logistics_board = {}

logistics_board.MONITOR_TYPE = "monitor"
--- Peripheral type of Create's Display Link (Create 0.5.1, 1.20.1).
logistics_board.DISPLAY_LINK_TYPE = "Create_DisplayLink"

local BAR_WIDTH = 8

--- Pick the largest text scale at which the board is still useful.
-- @tparam table monitor A wrapped monitor.
function logistics_board.fit_scale(monitor)
  for _, scale in ipairs({ 1, 0.5 }) do
    monitor.setTextScale(scale)
    local width = monitor.getSize()
    if width >= 26 then
      return
    end
  end
end

local function bar(count, limit, width)
  local filled = math.min(width, math.floor(count / math.max(limit * 2, 1) * width + 0.5))
  return string.rep("=", filled) .. string.rep(".", width - filled)
end

--- Draw the board on a terminal-like target (a monitor or a window).
-- @tparam table target
-- @tparam table data
-- @tparam[opt=1] number page Which page of rows, when they do not all fit.
-- @treturn number The number of pages.
function logistics_board.render(target, data, page)
  page = page or 1
  local pages = 1
  ui.draw_on(target, function()
    local width, height = ui.size()
    local rows_per_page = math.max(1, height - 2)
    pages = math.max(1, math.ceil(#data.rows / rows_per_page))
    page = math.min(page, pages)
    ui.clear()

    local low = 0
    for _, row in ipairs(data.rows) do
      if row.is_low then
        low = low + 1
      end
    end
    local summary = low > 0 and (low .. " low") or "all ok"
    ui.header(1, data.title or "Logistics", summary)

    local show_bar = width >= 34
    local first = (page - 1) * rows_per_page + 1
    for index = first, math.min(#data.rows, first + rows_per_page - 1) do
      local row = data.rows[index]
      local y = index - first + 2
      local amount = row.count .. "/" .. row.limit
      local right = amount
      if show_bar then
        right = bar(row.count, row.limit, BAR_WIDTH) .. " " .. amount
      end
      local label_width = width - #right - 2
      local role = row.is_low and "error" or "text"
      ui.text_at(1, y, ui.pad(row.label, label_width), role)
      ui.text_at(width - #right + 1, y, right, row.is_low and "error" or "dim")
    end

    local footer = data.updated and ("updated " .. data.updated) or ""
    if pages > 1 then
      footer = footer .. "  page " .. page .. "/" .. pages
    end
    ui.text_at(1, height, ui.fit(footer, width), "faint")
  end)
  return pages
end

--- Draw the board on a Create Display Board (text only, no colours).
-- A Display Link reports its size as rows, then columns.
-- @tparam table link A wrapped Display Link peripheral.
-- @tparam table data
function logistics_board.render_display_link(link, data)
  local rows, columns = link.getSize()
  link.clear()
  local lines = { (data.title or "Logistics") }
  for _, row in ipairs(data.rows) do
    local amount = row.count .. "/" .. row.limit .. (row.is_low and " LOW" or "")
    local label_width = math.max(1, columns - #amount - 1)
    lines[#lines + 1] = ui.pad(row.label, label_width) .. " " .. amount
  end
  for index = 1, math.min(rows, #lines) do
    link.setCursorPos(1, index)
    link.write(ui.fit(lines[index], columns))
  end
  link.update()
end

--- Blank a monitor or Display Link that no longer shows the board.
-- @tparam table peripheral_api The peripheral API (tests pass a stub).
-- @tparam string name
function logistics_board.clear(peripheral_api, name)
  local device = peripheral_api.wrap(name)
  if not device then
    return
  end
  device.clear()
  if peripheral_api.hasType(name, logistics_board.DISPLAY_LINK_TYPE) then
    device.update()
  end
end

--- Draw on whatever the named peripheral is (monitor or Display Link).
-- @tparam table peripheral_api The peripheral API (tests pass a stub).
-- @tparam string name
-- @tparam table data
-- @tparam[opt] number page
-- @treturn[1] number Pages drawn.
-- @treturn[2] nil
-- @treturn[2] string error message
function logistics_board.show(peripheral_api, name, data, page)
  local device = peripheral_api.wrap(name)
  if not device then
    return nil, "no peripheral named " .. name
  end
  if peripheral_api.hasType(name, logistics_board.DISPLAY_LINK_TYPE) then
    logistics_board.render_display_link(device, data)
    return 1
  end
  if peripheral_api.hasType(name, logistics_board.MONITOR_TYPE) then
    return logistics_board.render(device, data, page)
  end
  return nil, name .. " is not a monitor or a Display Link"
end

return logistics_board
