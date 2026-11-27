-- StorageMonitor parts against fake hardware: storage sources, alarms, boards.
return function(t)
  t.it("the inventory source adds up chests and reads labels once", function()
    local import = t.fresh_import()
    local inventory = import("storage_sources/inventory")
    local detail_calls = 0
    local chest = t.fake_chest({
      [1] = { name = "minecraft:cobblestone", count = 64, label = "Cobblestone" },
      [2] = { name = "minecraft:cobblestone", count = 10, label = "Cobblestone" },
    })
    local original_detail = chest.methods.getItemDetail
    chest.methods.getItemDetail = function(slot)
      detail_calls = detail_calls + 1
      return original_detail(slot)
    end
    inventory.peripheral = t.fake_peripherals({
      chest_0 = chest,
      chest_1 = t.fake_chest({
        [5] = { name = "minecraft:cobblestone", count = 6, label = "Cobblestone" },
      }),
      monitor_0 = { types = { "monitor" }, methods = {} },
    })
    local sources = { inventory }
    local totals, blocks = import("logistics_sources").read_all(sources)
    t.eq(blocks, 2, "only inventories are read")
    t.eq(totals["minecraft:cobblestone"].count, 80)
    t.eq(totals["minecraft:cobblestone"].label, "Cobblestone")
    t.eq(detail_calls, 1, "labels are cached")
  end)

  t.it("a chest that breaks mid-read is skipped", function()
    local import = t.fresh_import()
    local inventory = import("storage_sources/inventory")
    local broken = t.fake_chest({})
    broken.methods.list = function() error("block removed") end
    inventory.peripheral = t.fake_peripherals({
      broken = broken,
      chest = t.fake_chest({ [1] = { name = "x", count = 3, label = "X" } }),
    })
    local totals, blocks, failures = import("logistics_sources").read_all({ inventory })
    t.eq(blocks, 1)
    t.eq(totals.x.count, 3)
    t.eq(#failures, 1, "the broken chest is reported for the log")
    t.eq(failures[1].handle, "broken")
    t.ok(failures[1].error:find("block removed"), failures[1].error)
  end)

  t.it("every file in storage_sources is found as a source", function()
    local import = t.fresh_import()
    local root = t.sandbox .. "/tree"
    t.write(root .. "/lib/storage_sources/one.lua", "return {}")
    local loaded = {}
    local function loader(name)
      loaded[#loaded + 1] = name
      return { kind = name, read = function() return {} end, detect = function() return {} end }
    end
    local sources = import("logistics_sources").load(root, loader)
    t.eq(#sources, 1)
    t.eq(loaded[1], "storage_sources/one")
  end)

  local function fake_alarm_env(import)
    local alarms = import("logistics_alarms")
    local relay_outputs, computer_outputs, sent, notes = {}, {}, {}, {}
    alarms.env = {
      peripheral = t.fake_peripherals({
        redstone_relay_0 = {
          types = { "redstone_relay" },
          methods = { setOutput = function(side, on) relay_outputs[side] = on end },
        },
        speaker_0 = {
          types = { "speaker" },
          methods = {
            playNote = function(instrument) notes[#notes + 1] = instrument end,
            playSound = function(name) notes[#notes + 1] = name return true end,
            playAudio = function() notes[#notes + 1] = "audio" return true end,
          },
        },
      }),
      redstone = { setOutput = function(side, on) computer_outputs[side] = on end },
      send = function(recipient, message, protocol)
        sent[#sent + 1] = { recipient = recipient, message = message, protocol = protocol }
      end,
      broadcast = function(message, protocol)
        sent[#sent + 1] = { recipient = "everyone", message = message, protocol = protocol }
      end,
    }
    return alarms, relay_outputs, computer_outputs, sent, notes
  end

  t.it("redstone outputs switch on relays and the computer, and off again", function()
    local import = t.fresh_import()
    local alarms, relay, computer = fake_alarm_env(import)
    local applied = alarms.apply_redstone({
      ["redstone_relay_0|top"] = { target = "redstone_relay_0", side = "top", is_on = true },
      ["computer|back"] = { target = "computer", side = "back", is_on = true },
    }, {})
    t.eq(relay.top, true)
    t.eq(computer.back, true)
    alarms.apply_redstone({}, applied)
    t.eq(relay.top, false, "outputs no longer configured are switched off")
    t.eq(computer.back, false)
    local targets = alarms.list_outputs()
    t.eq(targets[1].target, "computer")
    t.eq(targets[2].target, "redstone_relay_0")
  end)

  t.it("the alarm sound can be a note, a Minecraft sound or a file", function()
    local import = t.fresh_import()
    local alarms, _, _, _, notes = fake_alarm_env(import)
    t.ok(alarms.chime())
    t.eq(notes[1], "bell")
    t.ok(alarms.chime({ kind = "sound", value = "minecraft:block.bell.use" }))
    t.eq(notes[#notes], "minecraft:block.bell.use")
    local ok, err = alarms.chime({ kind = "file", value = "/missing.dfpwm" })
    t.ok(not ok)
    t.ok(err:find("no sound file"), err)
    local clip = t.sandbox .. "/alert.dfpwm"
    t.write(clip, string.rep("U", 64))
    t.ok(alarms.chime({ kind = "file", value = clip }), "a .dfpwm file decodes and plays")
    t.eq(notes[#notes], "audio")
    t.ok(not alarms.validate_sound({ kind = "music", value = "x" }))
  end)

  t.it("alerts go once per change, only to the given computers", function()
    local import = t.fresh_import()
    local alarms, _, _, sent = fake_alarm_env(import)
    local states = { iron = { label = "Iron", count = 3, limit = 10, is_low = true } }
    local alerts = alarms.send_alerts("hub-pc", states,
      { went_low = { "iron" }, recovered = {} }, { 12, 13 })
    t.eq(#alerts, 1)
    t.eq(#sent, 2)
    t.eq(sent[1].protocol, "blockos.logistics.alert")
    t.ok(import("wire").parse(sent[1].message, "event", alarms.ALERT_SCHEMA))
    alarms.send_alerts("hub-pc", states, { went_low = {}, recovered = {} }, { 12 })
    t.eq(#sent, 2, "no change, no alert")
    local went_low = { went_low = { "iron" }, recovered = {} }
    alarms.send_alerts("hub-pc", states, went_low, alarms.EVERYONE)
    t.eq(sent[3].recipient, "everyone", "open access: one broadcast")

    local cleared = { label = "Gold", count = 2, limit = 10, is_low = false }
    local unwatched = { went_low = {}, recovered = { "gold" }, cleared = { gold = cleared } }
    local final = alarms.send_alerts("hub-pc", {}, unwatched, { 12 })
    t.eq(final[1].item, "gold")
    t.eq(final[1].is_low, false, "an unwatched item gets a final all-clear")
  end)

  local BOARD_DATA = {
    title = "Stock",
    updated = "12:00",
    rows = {
      { label = "Iron Ingot", count = 3, limit = 10, is_low = true },
      { label = "Cobblestone", count = 500, limit = 100, is_low = false },
    },
  }

  t.it("the board draws on small and large screens", function()
    local board = t.fresh_import()("logistics_board")
    for _, size in ipairs({ { 18, 5 }, { 39, 13 }, { 60, 20 } }) do
      local screen = window.create(term.current(), 1, 1, size[1], size[2], false)
      local pages = board.render(screen, BOARD_DATA)
      t.ok(pages >= 1)
      t.ok(screen.getLine(2) ~= nil)
    end
  end)

  t.it("the board pages through rows that do not fit", function()
    local board = t.fresh_import()("logistics_board")
    local rows = {}
    for i = 1, 20 do
      rows[i] = { label = "Item " .. i, count = i, limit = 5, is_low = i < 5 }
    end
    local screen = window.create(term.current(), 1, 1, 30, 6, false)
    t.eq(board.render(screen, { title = "Stock", rows = rows }), 5)
  end)

  t.it("a Create Display Link gets plain text lines with LOW markers", function()
    local board = t.fresh_import()("logistics_board")
    local written, updated = {}, false
    local link = {
      getSize = function() return 4, 24 end, -- rows, then columns
      clear = function() written = {} end,
      setCursorPos = function(_, y) written.y = y end,
      write = function(text) written[written.y] = text end,
      update = function() updated = true end,
    }
    board.render_display_link(link, BOARD_DATA)
    t.ok(updated, "update() must be called")
    t.eq(written[1], "Stock")
    t.ok(written[2]:find("LOW"), written[2])
    t.ok(#written[2] <= 24)
    t.ok(not written[3]:find("LOW"))
  end)

  t.it("a board that is turned off is blanked", function()
    local board = t.fresh_import()("logistics_board")
    local calls = {}
    local link = {
      clear = function() calls[#calls + 1] = "clear" end,
      update = function() calls[#calls + 1] = "update" end,
    }
    local fake_peripheral = {
      wrap = function() return link end,
      hasType = function(_, kind) return kind == board.DISPLAY_LINK_TYPE end,
    }
    board.clear(fake_peripheral, "display_link_0")
    t.eq(calls[1], "clear")
    t.eq(calls[2], "update", "a Display Link only shows changes after update()")
  end)
end
