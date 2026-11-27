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
| `blockos autologin <user>` | Log a local user in at boot (farms, displays, turtles) |
| `blockos motd <text>` | A message of the day on the login screen |

## Optional packages

The base install only contains what a device needs to join the network. Extra software comes
as optional packages, installed from a release (`pkg install <name>`) or from an add-on disk
(`pkg install <name> --disk`). Packages are split by what a computer needs, so every computer
installs only its part (`pkg list` shows the kind):

| Kind | What it holds | Examples |
|---|---|---|
| protocol | how computers talk to a service, and its client library | `logistics-protocol`, `mail-protocol` |
| library | code several applications share | `logistics-hub` |
| application | what runs on a computer (services) | `logistics-node`, `mail-server`, `turtle-remote` |
| tools | commands and screens people use | `logistics-tools`, `domain-tools`, `mail-tools` |
| bundle | nothing but other packages | `logistics` (tools and boards for a player's computer) |

Protocol and library packages come along by themselves as dependencies. A storage node needs
`logistics-node` and nothing to type into; a player's computer gets `logistics`.

| Family | On the computer that serves it | On players' computers |
|---|---|---|
| Domain | `domain-controller` (alone, with `mail-server` allowed next to it) | `domain` (every joined computer), `domain-tools` for admins (`dsa`, `rsh`, `profile`) |
| Logistics | `logistics-node` (next to chests), `logistics-controller`, `logistics-crafter` | `logistics` (or `logistics-tools` / `logistics-display` alone) |
| Mail | `mail-server` (needs disk drives) | `mail-client` (notices, sound), `mail-tools` (the mail app) |
| Messages | | `msg` (receives), `msg-tools` (the msg command) |
| Turtles | `turtle-remote` on the turtle | `turtle-tools` (the remote command) |
| Players | `player-locator` (next to a Player Detector) | none (turtles ask it) |
| Alerts | `alerts-hub` (one per network; fine on the domain controller) | `alerts-tools` (the alerts command) |
| Packages | `pkg-server`, `pkg-server-tools` | |

## A domain (one login for all computers)

1. On a computer that will do nothing else: `pkg install domain-controller`, then `dcpromo`
   (choose a domain name like `home` and the first domain admin).
2. On every other computer or turtle: `pkg install domain`, then `domain join home` and log in
   with any domain account when asked.
3. Log in with domain accounts from then on. Local accounts still work as `.\name`, for example
   when the controller is down.
4. Manage users, groups, computers and service records with `dsa` (full screen) or the admin
   commands of `domain`: install `domain-tools` on the computers you manage from.

**Managed mode.** Every package works on its own and open. In a domain, packages that have roles
(for example turtle-remote's `turtle-drivers`) stay open until a domain admin runs
`domain setup <package>`; the login screen reminds you. The setup creates the roles with friendly
defaults (everyone may use it, you administer it). Narrow them later in `dsa` (Groups tab: `e`
switches "everyone" on or off) or with `domain group`. A module's admins (e.g. `logistics-admins`)
manage its roles themselves, without a domain admin. `domain setup` lists what is set up.

**Computer roles (install and update from one place).** In `dsa`, Roles tab, `a` adds a role
for a kind of computer, e.g. `farm-display`: type its name, then tick its packages in the list
of what your package server (or the latest release) offers, then tick the computers that get
it. Space ticks, Enter saves. Later, `p` changes its packages, `c` its computers and `s` adds a
setting such as `blockos.autologin farmer`; in the Computers tab `o` ticks one computer's
roles. Every joined
computer installs what its roles list and keeps all its packages up to date from your package
server by itself: within 30 minutes, at boot, or right away with `domain update` on it. Updates
apply when nobody is logged in; otherwise you get a notice and it happens after you log out.

**Remote admin.** Domain admins manage any joined computer from `dsa` (Computers tab): `i` shows
its health (version, services, disk, turtle fuel and position), `u` updates it now, `b` reboots
it, `s` starts or stops a service, `l` reads its log, and `c` opens a **remote shell**: its
screen on yours, your keys on it, like ssh. `rsh <computer>` does the same from any shell. Hold
Ctrl+T to leave; F12 sends Ctrl+T to the remote computer.

**Roaming profiles.** Your apps and some settings follow you to every joined computer.
`profile app add logistics` opens logistics in its own tab whenever you log in on an advanced
computer (basic ones list your apps on the welcome screen); `profile set
blockos.logistics.server kitchen` makes every terminal you log into use that controller.
`profile` shows yours, `profile keys` which settings can follow you. Profile settings apply
only while you are logged in and never change the computer's own settings.

**Mail.** Install `mail-server` on a computer with disk drives (the domain controller's computer
is fine, it is allowed next to it). `pkg install` waits until a floppy is in a drive; it needs
one of its own (a BlockOS install disk doesn't count). Mailboxes live on the floppies, never on the computer, and
move to the next disk when one is full. Players install `mail-tools` and `mail-client`. `mail`
opens the mail app: folders (Inbox, Sent) on the left, the messages at the top, the selected one
below (on pocket computers one screen after the other); `n` writes, `r` answers, `d` deletes.
`mail send bob the iron farm is jammed` still works from scripts, and `mail send miners ...`
reaches every member of a group. The server keeps the newest 20 messages per folder.

New mail arrives at once on the computer you are logged into, with a sound from an attached
speaker: a "ding dong" by default. Pick your own with `profile set blockos.mail.sound
file:/sounds/mail.dfpwm` (any clip converted to DFPWM, like music), `note:<instrument>`,
`sound:<minecraft sound>` or `off`; it follows you to every computer. Your own scripts can
react too: the `blockos_mail` event carries the sender and how many messages are unread.

## Alerts (Discord, mail, other computers)

Anything that needs attention (an item running low, a reactor too hot, a farm jammed) is raised
as an alert, and one **alert hub** decides who hears about it. Install `alerts-hub` on one
computer (the domain controller's computer is fine) and `alerts-tools` where you manage it.
Then add channels:

```
alerts add discord discord https://discord.com/api/webhooks/123/abc --level=warn
alerts add miners mail miners --source=logistics
alerts add wall computer wall --level=info
alerts test discord
```

Kinds: `discord` (a webhook URL from the Discord channel's Integrations settings), `webhook`
(any URL; each alert is POSTed as JSON), `mail` (a user or group; needs a mail server) and
`computer` (a hostname, `#id` or `everyone`; `alerts watch` there shows them, e.g. on a monitor
with `monitor top alerts watch`). Each channel takes alerts from `--level` up (default `warn`),
only from the `--source`s you name, and says when a problem is over unless `--no-resolved`.
`alerts` lists what is active and what happened lately, `alerts channels` how delivery goes.
Discord and webhooks need HTTP, which CC:Tweaked allows by default.

What reaches the hub by itself:

- **Every joined computer's problems**, through the domain controller: a service that keeps
  crashing, a mail server without a floppy, a player locator without its detector, a logistics
  node that reports too much, the controller's own disk filling up. When it is fixed, the
  channels hear that too (unless `--no-resolved`).
- **Computers that stop reporting** (info level: often just an unloaded chunk, so only channels
  with `--level=info` hear of it).
- **Logistics**: items going low and recovering, storage nodes that stop reporting, failed
  crafting jobs (source `logistics`).

Computer problems have source `system`, so `--source=system` or `--source=logistics` splits
them between channels. Your own scripts raise alerts with
`alerts send --level=error --source=reactor --key=heat Reactor too hot` (and
`--level=ok ... Reactor cool` when it is over), or from Lua:

```lua
import("alerts").raise({ source = "reactor", key = "heat", level = "error",
  title = "Reactor too hot", text = "1840 C" })
```

Raise as often as you like: while a problem is active, the same alert is sent again at most
every 5 minutes. In a domain, `domain setup alerts` limits who may change channels to
`alerts-admins`.

## A package server

`pkg install pkg-server pkg-server-tools`, then `pkgserver import --latest`. Packages are kept
on the computer itself until it is full, then on the floppies of attached disk drives (add as
many as you like with wired modems). It registers itself in the domain,
so other computers install and update from it right away: `pkg` uses a package server when it
finds one (setting, domain record or the network) and GitHub otherwise (`--github` forces it).
`pkgserver allow <name> <group>` limits a package to a group.

## Logistics

Know what you have and where, get items delivered, and know when you are running out, with
lamps, a sound and a board. The packages:

- **logistics-node**, on the computer next to a group of chests (attach as many as you like
  with wired modems; Create Item Vaults work too). It counts them, sorts input chests into
  storage and delivers requested items. Nothing to set up: the wired modem that sees chests
  becomes the node's storage network (closed for rednet, so it never mixes with the main
  network); its other modem talks to the controller.
- **logistics-controller**, on a computer of its own: merges every node into one catalog,
  routes requests to the node that can deliver, and runs the levels (limits and alarms).
- **logistics-crafter**, on a node next to its machines: crafts by following recipes.
- **logistics** for players' computers: a bundle of `logistics-tools` (the `logistics`
  command) and `logistics-display` (boards, lamps, sound, notices). Either works alone.

**Start small:** a single node works alone. Run `logistics` on it and everything works there
(catalog, requests, levels, map). When you add a controller later, the node finds it and
reports to it, and `logistics levels import <node>` on the controller moves the node's limits
over. Many small nodes count faster than one big one (every chest read costs a game tick).

Run `logistics` (from any computer once there is a controller):

- **Overview:** counts against limits.
- **Catalog:** every item; `g` gets some, `w` watches it (a limit), `W` watches everything.
- **Alarms:** redstone outputs per item, plus the alarm sound.
- **Alerts:** recent changes.
- **Storage:** every chest with its node and role (see below).
- **Nodes:** each node, how many chests and items it has, and when it last reported.

Alarms:

- **Lamps:** on the controller, or on Redstone Relays on its wired network. Feed a Create
  Redstone Link to light lamps wirelessly.
- **Speaker:** plays a note, any Minecraft sound, or a `.dfpwm` recording (an "ALERT!" voice
  clip works). Set it with `logistics sound ...`.
- **Board:** `logistics board <monitor or Display Link>`, on any computer. A big monitor (about
  5x3 blocks) shows the **wall**: the controller on the left, every node stacked on the right
  with its chests coloured by how full they are, items flying along the rows as they move,
  and low items, alerts and recent moves under the controller. Nodes that can reach GPS
  hosts are grouped by height. Smaller monitors and Display Links show the list of levels
  (`logistics board <name> list` forces it).

**Run a farm until it is refilled:** give an item a refill target (Overview tab, `f`), for
example "low below 200, refill to 1000". An alarm output for that item then stays on until
the target is reached, so it can drive the farm directly. To drive a farm next to *another*
computer, add a reaction there: `logistics react add iron computer back`. Reactions follow the
real levels, so a missed alert (an unloaded chunk) never leaves the farm running.

**Chest roles.** Every chest has a role, set in the **Storage** tab (or
`logistics storage role <chest> <role>`):

- **storage** (the default for chests, barrels, drawers, vaults and crates): counted, and where
  items are sorted into and taken from.
- **input**: a dump chest, emptied into storage automatically (next to the same item first).
- **output**: where requested items arrive: `g` in the Catalog tab, or
  `logistics request iron 64 [output]` from any computer.
- **ignore** (the default for everything else: furnaces, machines, trash cans): never counted
  or touched, so sorting never fills a machine by accident.
- **port**: how items cross between nodes (see below).
- **machine**: a crafting machine's block (see Crafting); never counted or sorted into.
- **recycle**: the input of a recycling setup (Create crushing wheels, a mill...): scrap from
  failed crafts goes here instead of into storage.

Give chests labels with `l`. To find out which chest is which, press `f` and drop any item into
it (sorting pauses meanwhile). A chest whose modem was re-placed gets a new name; its old entry
shows as **missing**, and `d` forgets it. Two nodes may both have a `minecraft:chest_0`: name
it as `node/chest` then.

**Ports: items between nodes.** Run one wired cable, the main cable, from the controller past
every node. Next to each node, put a chest with two modems: one on the node's storage cable,
one on the main cable, both switched on (red). Give it the **port** role (`t` in the Storage
tab). The controller pairs it by itself: the node drops one item in, and the controller sees
which chest on its cable changed (the Storage tab shows "pairing", then "paired"). From then
on a request for an output on node B takes what B lacks from the node that has the most:
node A fills its port, the controller moves the items to B's port over the main cable, and B
puts them into the output. Anything left in a port goes back into storage on the next
round.

**Depots.** Give an output chest a position and it becomes a depot: `p` in the Storage tab,
or `logistics storage pos <chest> here` from a pocket computer standing next to it (GPS), or
`x y z`. `logistics request coal 16 here` then delivers to the nearest depot that has enough,
and `logistics depots` lists them by distance. Programs do the same with `logistics_api`,
e.g. a mining turtle that refuels on its way:

```lua
local logistics_api = import("logistics_api")
local result, err = logistics_api.request("minecraft:coal", 16, { here = true })
-- result.pos is where the depot is, result.moved how many are waiting there
```

**Crafting.** `pkg install logistics-crafter` on a node next to its machines (a Create mixer's
basin, a press's depot, a deployer's chest...), and give those blocks the **machine** role.
Then teach a recipe by doing it once: `logistics craft teach create:brass_ingot`, put the
ingredients into the machines yourself, and press Enter once the result is there. The node
saves what went where and how long it took (adjust with `logistics craft show/step/set`, or
write a recipe by hand with `logistics craft new`). For Create's sequenced assembly, list the
scrap item (`logistics craft set <item> scrap create:...`): a run that ends in scrap empties
the machines and starts over, up to the recipe's retries. The scrap goes to a **recycle**
chest when the node has one (scrap already in storage follows within half a minute); point the
recycler's output at an input chest and what it recovers is sorted back into storage, ready
for the next run.

Jobs run side by side as long as they use different machines; two recipes for the same
basin take turns. Built three mixers? Make them a group, `logistics craft group mixers basin_1
basin_2 basin_3`, and point the recipe at it (`logistics craft set create:brass_ingot machine
basin_1 @mixers`): every run takes a free mixer, so three batches go at once. A station of
several blocks (a depot and its output chest) is written `depot_1,out_1`, and the recipe uses
`@presses:1` and `@presses:2`. A supply step can name a slot, e.g. a furnace's fuel slot.

Watched items keep themselves stocked: when one drops below its limit and a node has a recipe,
that node crafts it up to the refill target. Ingredients come from the node's own storage
first; missing ones are brought from other nodes through the ports, straight into the machine.
The crafter talks to its node on the same computer, so watching the machines adds no network
traffic. `logistics craft` (or the Crafting tab) shows what can be crafted and the jobs;
`logistics craft brass 16` starts one by hand.

`logistics map` (or `m` in the Storage tab) shows a node as a map: inputs and outputs on the
left, storage on the right with fill bars, and items flying along the lines as they are sorted
or requested; Tab shows the next node. Advanced computers get colours and mouse clicks; basic
ones a plain text map. Select a chest (arrows and Enter, or a click) to label it, change its
role or get items into an output.

**Who may do what.** Open to everyone, like every module, until a domain admin runs
`domain setup logistics`: then `logistics-users` may look and request (everyone by default)
and `logistics-admins` may change levels, alarms and chest roles. To keep one node to some
players (Alice's magic storage), `logistics node private <node>` creates the role
`logistics-node-<node>`; take `everyone` off it and add its members, and nobody else sees that
node's items.

**Coming from storage-monitor:** `pkg install logistics-node` on the old stock computer
replaces it. On its first start it takes over the chest roles and labels and keeps the old
limits and alarms running on the node itself. On other computers, `pkg install logistics` (and
`pkg remove storage-monitor`); settings like `blockos.stock.board` move to
`blockos.logistics.*` by themselves.

## Driving turtles

`pkg install turtle-remote` on the turtle and `pkg install turtle-tools` where you drive from,
then `remote <turtle>` (`remote list` shows them). `w`/`s` move, `a`/`d` turn, space and `c`
go up and down, `f`/`r`/`v` dig, `e`/`t`/`g` place.

**The map.** Next to the inventory you see what the turtle sees, from above and turned with
it, so ahead is always up: `#` walls, `.` floor you can stand on, `~` water (red: lava), `&`
trees and plants, `C` chests, `@` machines, and the arrow is the turtle. Every turtle knows
what is directly in front, above and below. Make it a **Geoscanning Turtle** (Advanced
Peripherals' Geo Scanner on a turtle) and the map fills in 8 blocks around it. `z`/`x`
show the level below or above, `l` looks again, `m` switches between map and inventory on
small screens. The turtle works out which way it faces from GPS after the first step, or by
comparing the block in front with the scan; until then the map points north and shows `?`.

**Follow a player.** Press `p` and type a name: the turtle walks after that player and stays
about 3 blocks away. It never digs; it goes around or climbs over what is in the way. Any move
key takes over again, `p` stops it. It stops by itself when stuck, low on fuel, when the
player is more than 128 blocks away or out of sight for half a minute. It needs GPS hosts and
one **player locator** somewhere: a computer with an Advanced Peripherals Player Detector next
to it and `pkg install player-locator` (one is enough for the whole world).

## Music

`pkg install music`, then `music <song.dfpwm> [volume]` plays a song on every attached speaker
(a link to a `.dfpwm` file works too). `+`/`-` change the volume, `q` stops. Convert songs to
DFPWM with an online converter (e.g. music.madefor.cc) before copying them over.

## Upgrading from 0.4

0.5 splits packages by what a computer needs (see Optional packages). `pkg update` updates
everything you have and brings new dependencies along, but the parts that became optional
packages of their own are only installed when you ask for them:

- Computers you manage the domain from: `pkg install domain-tools` (`dsa`, `rsh`, `profile`,
  `domain setup`).
- Mail now has its own server: `pkg install mail-server` on a computer with disk drives (the
  domain controller's computer is fine). Players: `pkg install mail-client mail-tools`. Old
  mailboxes on the controller are not carried over.
- Instant messages: `pkg install msg` to receive them, `msg-tools` for the `msg` command.
- Turtle drivers: `turtle-tools` replaces `turtle-driver`; `logistics-crafter` replaces
  `logistics-crafting` (both by themselves on update).

A computer role in `dsa` that lists the new packages installs them everywhere at once.

**Domain controllers from 0.4 or older** still have the `domain` package (it came along as a
dependency then), and `pkg update` there stops with "domain-controller must run alone on its
computer, but domain is also installed". Upgrade it once with

```
pkg install domain-controller --force
```

which updates everything like `pkg update` does (the `pkg update` of 0.6 and older ignores
`--force`). Newer versions allow `domain` and `domain-tools` next to the controller, so later
updates need nothing special. Install `domain-tools` there for `dsa`, which 0.4 had in `domain`.

## Recovery

If BlockOS keeps failing to start, it rolls back to the previous version by itself. You can
also put the install disk in and reboot: the menu offers **Boot**, **Upgrade/Reinstall**,
**Safe mode** (a plain CraftOS shell) and **Roll back**. Every release has the install disk as
`blockos-disk.zip`.

## Development

See [CLAUDE.md](CLAUDE.md) for the architecture, code style and conventions. Tests run in CI
inside the [CraftOS-PC](https://www.craftos-pc.cc) emulator (`tools/test.sh`). Pushing a `v*` tag
builds and publishes a release.
