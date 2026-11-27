-- session-apps: the first tab of a session on an advanced device when the user has
-- apps in their roaming profile. Opens each installed app in its own tab, then
-- becomes the shell of this tab. Started by the session (see session.lua).
for _, app in ipairs({ ... }) do
  if shell.resolveProgram(app) then
    shell.openTab(app)
  end
end
shell.run("/rom/programs/shell.lua")
