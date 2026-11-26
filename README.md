# BlockOS

A small network operating system for [CC:Tweaked](https://tweaked.cc) computers and turtles.
BlockOS gives every device a login, background services, a package manager, and a name on the
network, so your computers can find and talk to each other by name instead of by ID.

Built for CC:Tweaked 1.115 (SkyFactory 5), on basic and advanced computers and turtles.

## Install

**From a disk (no HTTP needed).** Download `blockos-disk.zip` from the
[latest release](https://github.com/Salanto/BlockOS/releases/latest) and unzip it onto a
floppy. In singleplayer, a floppy's files live in
`saves/<world>/computercraft/disk/<disk id>/`. Put the floppy in a disk drive next to the
computer (or turtle), reboot it, and choose **Install BlockOS**. Remove the disk when it's done.
The install disk fits on a standard 125KB floppy; if a server lowers `floppy_space_limit` in the
CC:Tweaked config, raise it again or use the online install.

**Online.** On the computer, run:

```
wget run https://github.com/Salanto/BlockOS/releases/latest/download/install.lua
```

Either way, the first boot asks you to create an administrator account.

## Everyday commands

| Command | What it does |
|---|---|
| `blockos` | Status: version, device, hostname, services |
| `blockos services` | List services and their state |
| `blockos start\|stop\|restart <service>` | Control a service (admins) |
| `blockos log [lines]` | Show the system log |
| `peers` | Other BlockOS devices on the network |
| `hostname [name]` | Show or change this device's network name |
| `pkg list` / `pkg install <name>` / `pkg remove <name>` | Manage optional packages |
| `pkg update` | Upgrade BlockOS and installed packages (`--check`, `-y`; `update` is a short alias) |
| `useradd`, `userdel`, `passwd` | Manage local accounts |
| `logout` | Log out (closes all tabs) |
| `msg <host> <text>` / `msg * <text>` / `msg` | Chat with other computers; `msg` shows your messages |
| `blockos autologin <user>` | Log a local user in at boot (farms, displays, turtles) |
| `blockos motd <text>` | A message of the day on the login screen |

## Optional packages

The base install only contains what a device needs to join the network. Extra software comes
as optional packages, installed from a release (`pkg install <name>`) or from an add-on disk
(`pkg install <name> --disk`).

## A domain (one login for all computers)

1. On a computer that will do nothing else: `pkg install domain-controller`, then `dcpromo`
   (choose a domain name like `home` and the first domain admin).
2. On every other computer or turtle: `pkg install domain`, then `domain join home` and log in
   with any domain account when asked.
3. Log in with domain accounts from then on. Local accounts still work as `.\name`, for example
   when the controller is down.
4. Manage users, groups, computers and service records with `dsa` (full screen) or `domain`.

**Managed mode.** Every package works on its own and open. In a domain, packages that have roles
(for example turtle-remote's `turtle-drivers`) stay open until a domain admin runs
`domain setup <package>`; the login screen reminds you. The setup creates the roles with friendly
defaults (everyone may use it, you administer it). Narrow them later in `dsa` (Groups tab: `e`
switches "everyone" on or off) or with `domain group`. A module's admins (e.g. `logistics-admins`)
manage its roles themselves, without a domain admin. `domain setup` lists what is set up.

## A package server

On a computer with disk drives (attach as many as you like with wired modems):
`pkg install pkg-server`, then `pkgserver import --latest`. It registers itself in the domain,
so other computers install and update from it right away: `pkg` uses a package server when it
finds one (setting, domain record or the network) and GitHub otherwise (`--github` forces it).
`pkgserver allow <name> <group>` limits a package to a group.

## Watching stock

Know when you are running out of something, with lamps, a sound and a board.

1. On the computer next to your chests (attach as many as you like with wired modems; Create
   Item Vaults work too): `pkg install storage-monitor`, then `stock setup`. It can watch
   everything already in the chests, with a limit at a share of the current count.
2. Run `stock` to adjust it:
   - **Overview:** counts against limits.
   - **Catalog:** watch more items.
   - **Alarms:** redstone outputs per item, plus the alarm sound.
   - **Alerts:** recent changes.
   - **Access:** who may look, configure, or receive alerts.
3. Wire up the alarms:
   - **Lamps:** on the computer, or on Redstone Relays anywhere on the wired network.
     Feed a Create Redstone Link to light lamps wirelessly.
   - **Speaker:** plays a note, any Minecraft sound, or a `.dfpwm` recording (an "ALERT!" voice
     clip works). Set it with `stock sound ...`.
   - **Board:** `stock board <monitor or Display Link>`, on the stock computer or any computer
     on its access list.

**Run a farm until stock is refilled:** give an item a refill target (Overview tab, `f`), for
example "low below 200, refill to 1000". An alarm output for that item then stays on until
the target is reached, so it can drive the farm directly. To drive a farm next to *another*
computer, put that computer on the stock computer's access list and add a reaction there:
`stock react add iron computer back`. Reactions follow the real stock state, so a missed
alert (an unloaded chunk) never leaves the farm running.

A stock computer is open by default: anyone can look and every computer gets its alerts; only
its admins (and domain admins) can change it. Narrow that in the Access tab if you like. It
works without a domain too.

## Music

`pkg install music`, then `music <song.dfpwm> [volume]` plays a song on every attached speaker
(a link to a `.dfpwm` file works too). `+`/`-` change the volume, `q` stops. Convert songs to
DFPWM with an online converter (e.g. music.madefor.cc) before copying them over.

## Recovery

If BlockOS keeps failing to start, it rolls back to the previous version by itself. You can
also put the install disk in and reboot: the menu offers **Boot**, **Upgrade/Reinstall**,
**Safe mode** (a plain CraftOS shell) and **Roll back**. Every release has the install disk as
`blockos-disk.zip`.

## Development

See [CLAUDE.md](CLAUDE.md) for the architecture, code style and conventions. Tests run in CI
inside the [CraftOS-PC](https://www.craftos-pc.cc) emulator (`tools/test.sh`). Pushing a `v*` tag
builds and publishes a release.
