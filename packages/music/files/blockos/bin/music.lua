-- music: play a .dfpwm song on every attached speaker.
--
--   music <file.dfpwm | https://...> [volume]
--
-- Keys while playing: + and - change the volume (0-3), q stops.
local args = { ... }
local ui = blockos.ui
local music = import("music")

local VOLUME_STEP = 0.5

local function print_usage()
  print("Usage: music <file.dfpwm | https://...> [volume 0-3]")
end

local function fail(message)
  ui.print(tostring(message), "error")
end

local function clamp_volume(volume)
  return math.max(0, math.min(music.MAX_VOLUME, volume))
end

local function draw(title, state)
  local width, height = ui.size()
  ui.clear()
  ui.header(1, "Music " .. ui.GLYPHS.dot .. " " .. title)
  local status = string.format("Volume %.1f   speakers %d", state.volume, state.speaker_count)
  ui.line(3, status, "text")
  if state.size then
    -- A progress bar across the screen, from bytes played.
    local bar_width = math.max(1, width - 2)
    local filled = math.floor(bar_width * math.min(1, state.played / state.size))
    ui.line(5, string.rep("#", filled) .. string.rep("-", bar_width - filled), "dim")
  else
    ui.line(5, string.format("%d KB played", math.floor(state.played / 1024)), "dim")
  end
  ui.line(height, ui.fit("+/- volume   q stop", width), "faint")
end

local function play(where, volume_text)
  local is_link = where:match("^https?://") ~= nil
  local path = is_link and where or shell.resolve(where)
  if not is_link and not path:match("%.dfpwm$") then
    ui.print("Note: only .dfpwm audio plays; other formats sound like noise.", "warn")
  end
  local speakers = music.find_speakers()
  if #speakers == 0 then
    return fail("No speaker attached.")
  end
  local song, err = music.open(path)
  if not song then
    return fail(err)
  end

  local title = is_link and (where:match("([^/]+)$") or where) or fs.getName(path)
  local state = {
    volume = clamp_volume(tonumber(volume_text) or 1),
    speaker_count = #speakers,
    played = 0,
    size = song.size,
    is_stopped = false,
  }
  draw(title, state)

  local function playback()
    music.play(song, speakers, {
      volume = function() return state.volume end,
      should_stop = function() return state.is_stopped end,
      progress = function(bytes)
        state.played = bytes
        draw(title, state)
      end,
    })
  end
  local function keys()
    while true do
      local _, char = os.pullEvent("char")
      if char == "q" then
        state.is_stopped = true
        return
      elseif char == "+" or char == "=" then
        state.volume = clamp_volume(state.volume + VOLUME_STEP)
      elseif char == "-" then
        state.volume = clamp_volume(state.volume - VOLUME_STEP)
      end
      draw(title, state)
    end
  end
  parallel.waitForAny(playback, keys)
  -- Stopped with q: silence what is still queued on the speakers.
  if state.is_stopped then
    for _, speaker in ipairs(speakers) do
      speaker.stop()
    end
    -- Playback was cut off before it could close the song.
    pcall(song.close)
  end
  ui.clear()
  ui.print(state.is_stopped and "Stopped." or "Finished.", "ok")
end

if not args[1] then
  print_usage()
else
  play(args[1], args[2])
end
