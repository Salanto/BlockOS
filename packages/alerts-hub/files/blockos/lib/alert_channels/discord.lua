--- Alert channel: a Discord channel, through a webhook (Channel settings, Integrations,
-- Webhooks, Copy Webhook URL). Each alert is one message with a coloured embed.
-- @module alert_channels.discord

local discord = {}

discord.kind = "discord"
discord.help = "a Discord webhook URL"

-- Embed colours per level (Discord wants a number, 0xRRGGBB).
local COLOURS = {
  info = 0x3498DB,
  warn = 0xF1C40F,
  error = 0xE74C3C,
  ok = 0x2ECC71,
}

local LABELS = { info = "Info", warn = "Warning", error = "Error", ok = "Resolved" }

--- Is this a Discord webhook URL? (discord.com, discordapp.com, ptb. and canary.)
-- @tparam string target
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string what is wrong
function discord.check(target)
  if not target:match("^https://[%w%.]-discord%a*%.com/api/webhooks/%d+/[%w_%-]+$") then
    return nil, "expected a webhook URL like https://discord.com/api/webhooks/123/abc"
  end
  return true
end

--- Short text for lists: the webhook's id, not its secret token.
-- @tparam string target
-- @treturn string
function discord.describe(target)
  local id = target:match("/webhooks/(%d+)/")
  return "Discord webhook " .. (id or "?")
end

--- The webhook message for an alert.
-- @tparam table alert
-- @treturn table
function discord.message(alert)
  return {
    username = "BlockOS",
    embeds = {
      {
        title = alert.title,
        description = alert.text,
        color = COLOURS[alert.level] or COLOURS.info,
        footer = {
          text = string.format("%s | %s on %s", LABELS[alert.level] or alert.level,
            alert.source, alert.host or "?"),
        },
      },
    },
  }
end

--- Post an alert.
-- @tparam string target The webhook URL.
-- @tparam table alert
-- @tparam table env { post = function(url, body) -> true | nil, err }
-- @treturn[1] true
-- @treturn[2] nil
-- @treturn[2] string error message
function discord.deliver(target, alert, env)
  return env.post(target, discord.message(alert))
end

return discord
