# BlockOS

## What this project is

BlockOS is a general-purpose, minimal **network operating system** for computers in the
**CC:Tweaked** Minecraft mod. Its goal is to make it easy for several in-game computers to
talk to each other over modems on a **rednet**-enabled network.

It models real-world networking concepts, deliberately simplified, so that PCs can communicate
seamlessly by name instead of by raw computer ID:

- **DNS**: our own name-resolution service mapping human-readable hostnames to computer IDs.
- **Dynamic computer lookup**: computers announce/discover each other at runtime, so the
  network keeps working as machines join, leave, reboot, or change roles.

## Target environment

- **Mod:** CC:Tweaked **1.115.0**
- **Modpack:** SkyFactory 5 (Minecraft 1.20.1, Forge)
- **Language:** Lua, as run by CC:Tweaked's Cobalt VM (Lua 5.2 semantics, with a few 5.3
  additions such as the `utf8` library). Do not use LuaJIT or Lua 5.4-only features
  (e.g. `<const>`, `<close>`, integer `//` should not be assumed).
- Code runs **inside the game**. For testing outside the game it runs in the **CraftOS-PC**
  emulator (see Testing). CraftOS-PC uses C Lua 5.2 rather than Cobalt and targets an older
  CC:Tweaked (about 1.112), so passing tests are strong evidence, not proof: still check
  behaviour in-game and against the CC:Tweaked docs (https://tweaked.cc).

## CC:Tweaked constraints to keep in mind

- **Yielding:** a computer that runs too long without yielding is killed
  ("Too long without yielding"). Long loops must yield (`os.pullEvent`, `sleep`, `coroutine.yield`).
- **Event-driven:** networking is built on events (`rednet_message`, `modem_message`, `timer`).
  Use `parallel.waitForAny` / `parallel.waitForAll` or a coroutine scheduler to run the network
  stack alongside user programs.
- **Modems:** wired modems (with networking cable), wireless modems (limited range), and ender
  modems (unlimited range, cross-dimension). A modem must be opened (`rednet.open(side)` or
  `peripheral.find("modem", rednet.open)`) before rednet works.
- **Built-in rednet:** `rednet.send`, `rednet.broadcast`, `rednet.receive(protocol, timeout)`,
  and the built-in `rednet.host` / `rednet.lookup` name service. Messages can be any
  serialisable Lua value (tables included).
- **No security by default:** any computer can send any message and claim any ID or hostname.
  Validate message shape before acting on it, so a buggy or misconfigured computer can't break
  others.
- **Filesystem:** each computer has its own disk (about 1MB; floppies hold 125KB).
  `startup.lua` (or `startup/`) runs on boot, and a disk's startup runs *instead of* the
  computer's own. Each program's `require` only searches next to that program and the rom, so
  BlockOS code uses the kernel's `import` instead (see Architecture).
- **No shutdown notice:** chunk unloads and server stops kill a computer without any event.
  Anything persistent must be written atomically (`fsx.write`).
- **Computer IDs** (`os.getComputerID()`) are stable per computer and are the underlying address
  that rednet uses; hostnames are BlockOS's layer on top.

## Security and authentication

A simple security layer loosely modelled on **Active Directory**, using **basic auth**
(decided: no NTLM-style challenge-response, no Kerberos, no message signing). It controls who
may log in, which packages a computer may pull, and who may use services and control panels.

| AD | BlockOS |
|---|---|
| Domain / domain controller | `dcpromo` (package `domain-controller`) creates a domain such as `home`; the controller serves protocol `blockos.domain`. It is **exclusive**: no other optional packages on it unless `--force`. |
| Users and groups | Stored on the controller. Flat groups; built in: `domain-admins`, `domain-users` (everyone), `computer-joiners`, `dns-admins`. |
| Computer accounts | `domain join` needs a domain admin or computer-joiner login. The computer gets a long-lived **computer token** (on disk on both sides; revoked by removing the account). It authorises status reports, user logins and system-to-system calls (`rpc.require_computer`). |
| Logging in | The password goes once, in plain text, to the controller, which returns a **session token** (fixed 8-hour lifetime, in the controller's memory only). Services check the token with the controller on **every** request (`rpc.require_user`): no cached logins, so logout and group changes apply at once. |
| Local accounts | Always available as `.\name`, e.g. when the controller is down. A bare name means a domain user once joined. Domain admins are admins on every joined computer. |
| AD-integrated DNS | The controller holds host records (`<host>.<domain>`, updated by each computer itself) and service records (e.g. `pkg -> storage`, created by domain-admins or dns-admins). |
| Users and Computers tool | `dsa` (full-screen) and `domain` (command line). |

Login providers: `auth.register_provider(name, provider)`; core has `local`, the `domain`
package adds `domain`. Left out on purpose: organisational units, group policy, trusts,
replication, cached logins.

**Threat model:** the network is used only by our own players; there are no outside
attackers. Do **not** design against man-in-the-middle, eavesdroppers, or malicious third
parties, and don't add encryption or hardening for them. The security layer exists to build a
proper, realistic network the fun way (accounts, domains, logins, permissions), and to
guard against accidents and misconfiguration, not adversaries.

Things to keep in mind:

- Keep it proportionate. Plaintext stored passwords are acceptable; at most use a simple salted
  hash. Don't implement SHA-256/HMAC or other crypto for auth.
- `math.random` is fine for session tokens and salts given the threat model.

## Design principles

- **Build our own:** this is a hobby project to build a proper network stack ourselves. Do not
  pull in or copy existing community OSes, networking libraries, or crypto/DNS packages; write
  our own implementation. (Using CC:Tweaked's built-in APIs, including rednet, is expected;
  see below.)

- **Reuse rednet, don't reinvent it:** if rednet already provides a feature (addressing,
  message delivery, protocol filtering, repeating, `rednet.host` / `rednet.lookup` name
  hosting, etc.), use it directly or build on top of it. Only implement our own version when
  rednet genuinely lacks the capability, and note in code/docs why the built-in wasn't enough.

- **Minimal:** small footprint, few files, easy to copy onto a fresh computer.
- **Simplified realism:** borrow concepts (DNS, discovery, protocols) from real networking, but
  drop complexity that doesn't pay off in-game.
- **Robust to churn:** computers and chunks unload, servers restart, players break things. Handle
  timeouts, stale entries, and missing peers gracefully.
- **Clear protocols:** every message type should have a named rednet protocol string and a
  documented message shape.

- **Lean base, optional extras:** the base install (`core` + `net`) does just enough to get a
  device onto the network. Specialised software (for example the auth server, or a service that
  polls machines on a subnet modem, ...) ships as **optional packages** installed with `pkg`.
- **Every device behaves the same:** basic and advanced computers and turtles (pockets later).
  See Device rules.

## Code style

Readability comes first. Based on the Olivine Labs and LuaRocks Lua style guides:

- **Naming:** `snake_case` for our variables, functions and fields; `PascalCase` only for class
  tables (e.g. `Scheduler`); `UPPER_CASE` for real constants. Booleans read as questions
  (`is_admin`, `is_online`). CC:Tweaked's own APIs are camelCase; that is fine, don't wrap them.
  Never name a variable `arg`.
- **Locals everywhere.** Modules return a table and set no globals. The only intentional
  globals are `blockos` (public API) and `import` (module loader).
- **Modules:** `local m = {}` ... `return m`; private helpers are `local function`; public
  functions are `function m.name()`. Import dependencies at the top into locals named after
  the module.
- **One statement per line.** `if` always gets a block. One-line functions are fine only for
  tiny lambdas such as `function() return x end`.
- **Small functions with early returns.** Split long functions into named steps
  (see `pkg.apply`).
- **Errors:** expected failures return `nil, "message"`; programming errors use `error()`.
  Programs called non-interactively signal failure by raising.
- **Formatting:** 2-space indent, double quotes, 100-column lines (enforced by luacheck).
- **Doc comments:** LDoc style. `---` summary sentence, then `@tparam type name`, `@treturn`,
  with `@treturn[1]`/`@treturn[2]` for `value` vs `nil, err` results. Each module starts with
  a `--- summary` and `@module name`. Comments explain *why*; the code shows *what*.

## Architecture

### Repository layout

```
packages/<name>/package.lua    manifest { name, version, description, depends, optional }
packages/<name>/files/...      files, at the path they are installed to (relative to /)
installer/install.lua          online installer (release asset)
tools/build.lua                builds release assets (runs in CraftOS-PC)
tools/craftos-run.sh           runs a program in a fresh headless CraftOS-PC computer
tools/test.sh                  run the tests in CraftOS-PC (used by CI)
tools/build.sh                 builds dist/ for a release
tests/run.lua, tests/*_spec.lua  test runner and specs (run inside CraftOS-PC)
```

Packages: `core` (kernel, session, package manager, installers) and `net` (modems, hostname,
peers). Both are required; anything else should be `optional = true`.

### On the device

```
/startup.lua            the loader (core/files/blockos/loader.lua); upgrades never replace it
/blockos/boot.lua       kernel entry point: sets up `blockos`, starts services and the session
/blockos/kernel/*.lua   core modules (paths, fsx, log, config, device, ui, auth, setup,
                        pkg, scheduler, services, session)
/blockos/lib/*.lua      modules from other packages (e.g. net)
/blockos/services/*.lua service definitions
/blockos/bin/*.lua      commands, prepended to the shell path
/blockos/packages.db    installed packages (inside the tree, so it always matches it)
/blockos.old/           previous version, for rollback
/etc/blockos/           passwd, bootcount, upgrade.state, startup.bak/
/var/log/blockos.log    system log (rotated at blockos.log.max_size, default 8KB; one old copy)
/.settings              CC settings; BlockOS keys are `blockos.*`, defaults defined in code
```

`import("name")` loads `/blockos/kernel/name.lua` or `/blockos/lib/name.lua` once. All paths
go through `paths.lua`, so tests and installers can redirect everything with `paths.prefix`.

### Boot and recovery rules

- The loader finishes or undoes an interrupted upgrade/rollback (`upgrade.state` = `swap` or
  `rollback`), counts boots that never reached the login screen, rolls back once at the 4th
  failure and gives up (plain CraftOS shell) at the 7th or when nothing is left to roll back to.
- The kernel resets `bootcount` once the login screen is up. If the kernel ever returns or
  crashes, the loader logs it and reboots: never fall through to an unauthenticated shell.
- Upgrades build the complete new tree in `/blockos.new`, check every `.lua` file compiles,
  then swap. Never write into `/blockos` in place. Space is checked first; if it is short the
  update refuses and says how much to free.
- The install disk doubles as the recovery disk (boot, upgrade, safe mode, rollback).
  Never set `shell.allow_disk_startup=false`.

### Services

`/blockos/services/<name>.lua` returns
`{ name, description, after, restart, condition, run(ctx) }`. Services run in the kernel's
scheduler, never receive `terminate`, and have `print`/`write`/`printError` redirected to the
log: they must never draw to the terminal. A crash restarts with backoff; 5 crashes in 2
minutes marks the service `failed`. `condition` returning false marks it `n/a`.

### Device rules

- Detect the device type only through `device.kind()` / `device.is_advanced()`.
- Choose colours only through `ui` theme roles; basic devices get a greyscale theme.
- Every screen must work with the keyboard alone; mouse input is optional.
- Lay out from `term.getSize()`; never assume 51x19 (turtles are 39x13).
- One session code path: advanced devices get a nested multishell and basic ones a plain
  shell; logout drops the whole session, including tabs.
- Turtle services only use read-only turtle functions (never move, dig or select).

### Wire protocols

| Protocol           | Message                                                        |
|--------------------|----------------------------------------------------------------|
| `blockos`          | rednet's built-in `rednet.host` / `rednet.lookup` hostname records |
| `blockos.announce` | event `announce` `{ hostname, kind, version, services, info, hello? }`, broadcast at boot and every 5 min, **only by computers not in a domain**; a `hello` gets a direct reply |
| `blockos.domain`   | rpc. join, leave, login, validate, logout, validate_computer, host_update, resolve, list_hosts, service_find/add/del, list_users/groups/computers/services, user_add/del/passwd/enable, group_add/del/addmember/rmmember, computer_remove, dc_status. The controller also hosts this protocol under the domain name, so `rednet.lookup("blockos.domain", "home")` finds it. |
| `blockos.pkg`      | rpc. index (filtered by the caller's groups), fetch `{ name }` (raw .pkg), publish `{ raw }` (domain-admins). |
| `blockos.stock`    | rpc. status, alerts (viewers, admins or listed computers); catalog, watches (viewers, admins); outputs, watch, unwatch, watch_all, settings, test_sound, access, set_access (admins). Found via the domain service record `stock` / `stock-<name>`. |
| `blockos.stock.alert` | event `stock_alert` `{ server, item, label, count, limit, is_low }`, sent directly to each computer on the stock computer's access list, only when an item goes low or recovers. |

**Wire format** (`net/lib/wire.lua`): every message uses one envelope, so nothing is parsed by
hand:

- request `{ v = 1, kind = "request", id, op, args, token?, computer_token? }`
- response `{ v = 1, kind = "response", reply_to, ok, result | error }`
- event `{ v = 1, kind = "event", topic, data }` (one-way: announces, alerts)

Each protocol declares its payload once as a schema (`{ hostname = { type = "string", max = 32 } }`).
Receivers call `wire.parse(message, kind, schema)`, and rpc handlers are wrapped in
`rpc.with_args(schema, fn)`. Unknown fields are ignored, and messages with a newer major version
are dropped. **New protocols must use wire and declare schemas.**

**rpc** (`net/lib/rpc.lua`): handlers return a result, or `nil, err`. Rednet has no
request/response, so rpc only adds reply matching, timeouts/retries and a server loop that
runs each request in its own coroutine.

**Discovery:** joined computers resolve names and services by asking the controller (one
direct message, answers cached 60s) instead of broadcasting; they still `rednet.host` their
name, which costs nothing unless queried. `rednet.lookup` is only used to find the controller
(and when it moved), and by computers without a domain. Reason (per "reuse rednet"): every
`rednet.lookup` is a broadcast plus a 2-second wait, and rednet has no service records, access
control or last-seen data. Short hostnames contain no "."; it is reserved for the domain
suffix.

Peer liveness uses the local receive time, never the sender's clock.

### Packages and releases

- A `.pkg` is `textutils.serialise({ manifest, files = { [path] = content } })`, compressed with
  `lz.lua` (LZ77-style, byte-oriented, "BLZ1" header; plain packages still decode).
  `index.lua` lists `{ version, depends, optional, size, sum }` per package (size and sum of the
  compressed file). Installed files are not compressed. The installers need `lz.lua` before
  they can open `core.pkg`, so it ships next to them on install disks and in releases.
- Sources (`pkg.disk_source`, `pkg.github_source`, `pkg_remote.source`) share one interface:
  `describe()`, `index()`, `fetch(name)`.
- Package server (`pkg-server`): stores packages in `<drive>/blockos-repo/` across every mounted
  drive (wired-modem drives included) plus the local disk; `pkgserver allow <name> <group...>`
  restricts a package. Clients use `--server[=name]`, the domain's `pkg` service record, or the
  `blockos.pkg.server` setting.
- Manifest flags: `optional` (not in the base install), `exclusive` (must run alone),
  `media_only` (path prefixes kept in the package for building disks but not installed).
- **Storage housekeeping:** `blockos status` shows where disk space goes; `blockos cleanup`
  deletes the previous version (no rollback afterwards) and the old log. Boot finishes or
  removes interrupted `.tmp` writes in `/etc/blockos`. The domain controller saves only
  accounts (status reports, sessions and exact last-seen times stay in memory; last-seen *day*
  is saved so stale computers survive restarts), caps reported info at 1KB, refuses changes
  when a save would not fit (logins and lookups keep working), and warns below 20% free.
- **Floppy budget:** core + net (compressed) must fit on one 125KB install disk (the build
  fails otherwise; servers can also raise `floppy_space_limit` in the CC:Tweaked config).
  The build shrinks packaged Lua files (comment-only lines emptied, indentation dropped) without
  changing line numbers, so keep writing fully commented source. `[[ ]]` long strings are not
  allowed in package files (the shrinker would break them).
- Releases: push a tag `vX.Y.Z` (or `vX.Y.Z-rcN` for a prerelease). CI tests, builds
  (`tools/build.sh`) and publishes `index.lua`, `*.pkg`, `install.lua`, `lz.lua`, `blockos-disk.zip`
  and `blockos-addon-<name>.zip` per optional package. Online installs use
  `releases/latest/download/...`, never `api.github.com` (rate limits are shared per server IP).

## Testing

- Tests run **inside CraftOS-PC** with the real CC APIs, in CI only (no local test scripts):
  `tools/test.sh [advanced|basic|both]` on the Linux runner. CI runs both computer
  types on every push. Headless CraftOS-PC always reports a colour terminal, so the runner
  simulates a basic computer with a terminal whose `isColour()` returns false; always detect
  the device type through `device.is_advanced()` so this stays accurate.
- Specs live in `tests/*_spec.lua` and return `function(t)`; use `t.it`, `t.ok`, `t.eq`,
  `t.fresh_import()` (modules redirected into `/sandbox`) and `t.with_input()` to type into
  prompts.
- CraftOS-PC does not emulate turtles: turtle logic is tested with a stub `turtle` table, and
  real turtle behaviour must be checked in-game.
- Lint with luacheck (`.luacheckrc`); CI runs it.

## Roadmap

- **Done (milestone 2):** rpc layer, domain controller with DNS, package server.
- **Milestone 3:** StorageMonitor (`storage-monitor` package): stock watching with limits,
  redstone/relay lamps, a speaker sound (note, Minecraft sound or .dfpwm file), monitor and
  Create Display Board boards, alerts to listed computers, a per-computer access list, refill
  targets and reactions on other computers (level-triggered: they poll status, alerts only
  speed them up); the shared wire format.
- **Next:** remote control for PCs and turtles, built on rpc, wire and domain logins. More
  storage sources (e.g. an ME/RS bridge) as separate packages adding
  `lib/storage_sources/<kind>.lua`.
- **Later:** uninstall of BlockOS itself, local IPC via custom events, tab completion,
  pocket computer support.

## Git

- Commit messages: one short summary sentence, then short bullet points.
- No Claude attribution in commits or PRs: no `Co-Authored-By`, no session URL, no
  "Generated with" lines.
