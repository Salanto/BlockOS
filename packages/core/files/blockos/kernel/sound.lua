--- Short sounds on an attached speaker: a note block instrument, a Minecraft sound
-- event, or a .dfpwm audio file. Used for logistics alarms and the new-mail sound.
--
-- A sound is { kind = "note" | "sound" | "file", value, volume? }:
--   note   a note block instrument ("bell", "chime", "pling")
--   sound  a Minecraft sound event ("minecraft:block.bell.use", or one from a mod)
--   file   a .dfpwm audio file on this computer (e.g. a recorded voice clip)
-- @module sound

local sound = {}

--- The peripheral API (tests replace it).
sound.env = { peripheral = peripheral }

local function find_speaker()
  local api = sound.env.peripheral
  for _, name in ipairs(api.getNames()) do
    if api.hasType(name, "speaker") then
      return api.wrap(name)
    end
  end
  return nil
end

-- CC's DFPWM decoder lives in the rom as a `require` module; services have no
-- `require` of their own, so build one. The loaded modules call `require`
-- themselves (cc.audio.dfpwm needs cc.expect), so it lives in their environment.
local function dfpwm_module()
  local make_require = dofile("/rom/modules/main/cc/require.lua").make
  local env = setmetatable({}, { __index = _ENV })
  env.require = make_require(env, "/")
  return env.require("cc.audio.dfpwm")
end

-- Stream a .dfpwm file through the speaker, chunk by chunk.
local function play_file(speaker, path, volume)
  local handle = fs.exists(path) and fs.open(path, "rb")
  if not handle then
    return nil, "no sound file at " .. path
  end
  local decoder = dfpwm_module().make_decoder()
  while true do
    local chunk = handle.read(16 * 1024)
    if not chunk then
      break
    end
    local samples = decoder(chunk)
    while not speaker.playAudio(samples, volume) do
      os.pullEvent("speaker_audio_empty")
    end
  end
  handle.close()
  return true
end

--- Check a sound.
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string error message
function sound.validate(value)
  if type(value) ~= "table" or type(value.value) ~= "string" or value.value == "" then
    return nil, "a sound needs a kind and a value"
  end
  if value.kind ~= "note" and value.kind ~= "sound" and value.kind ~= "file" then
    return nil, "the sound kind must be note, sound or file"
  end
  return true
end

--- Play a sound on an attached speaker, if there is one.
-- @tparam table value See the module comment.
-- @tparam[opt] {number...} pitches Notes to play for kind "note" (default 12, 8).
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string why nothing played
function sound.play(value, pitches)
  local speaker = find_speaker()
  if not speaker then
    return nil, "no speaker attached"
  end
  local volume = value.volume or 1
  if value.kind == "file" then
    return play_file(speaker, value.value, volume)
  elseif value.kind == "sound" then
    if not speaker.playSound(value.value, volume) then
      return nil, "the speaker did not play " .. value.value
    end
    return true
  end
  for _, pitch in ipairs(pitches or { 12, 8 }) do
    speaker.playNote(value.value, volume, pitch)
  end
  return true
end

return sound
