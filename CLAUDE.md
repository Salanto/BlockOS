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

## Security and authentication (planned)

BlockOS should add a simple security layer to the OS, loosely modeled on **Active Directory**,
using **basic auth** (decided: no NTLM-style challenge-response, no message signing). Its
purpose is to control which programs a computer may pull into its runtime and who can access
remote control/status panels.

- **Local accounts:** each computer can have local users stored on its own disk, as a
  fallback when no central server is reachable.
- **Central auth server (domain controller):** an optional server that holds domain accounts
  and their roles. Computers can "join the domain" so one set of credentials works across the
  network.
- **Basic auth login:** the client sends username + password to the auth server over rednet;
  the server checks them and returns a **session token** with an expiry and the user's roles.
- **Token-based requests:** later requests (program pulls, control-panel actions) carry the
  token, not the password. Services validate the token and check the role before acting.

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
tools/test.sh, tools/test.ps1  run the tests (Linux/CI and Windows)
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
/var/log/blockos.log    system log (16KB, one rotated copy)
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
| `blockos.announce` | `{ v = 1, hostname, kind, version, services = {...}, info = {...}, hello = true? }` broadcast at boot and every 30s; a `hello` gets a direct reply |

Every BlockOS message carries `v` (wire version). Receivers validate the shape, ignore unknown
fields, and drop messages with a newer major version. Peer liveness uses the local receive time.

### Packages and releases

- A `.pkg` is `textutils.serialise({ manifest, files = { [path] = content } })`.
  `index.lua` lists `{ version, depends, optional, size, sum }` per package.
- Sources (`pkg.disk_source`, `pkg.github_source`) share one interface: `describe()`,
  `index()`, `fetch(name)`. A future package server on the network is one more source.
- Releases: push a tag `vX.Y.Z` (or `vX.Y.Z-rcN` for a prerelease). CI tests, builds
  (`tools/build.sh`) and publishes `index.lua`, `*.pkg`, `install.lua`, `blockos-disk.zip`
  and `blockos-addon-<name>.zip` per optional package. Online installs use
  `releases/latest/download/...`, never `api.github.com` (rate limits are shared per server IP).

## Testing

- Tests run **inside CraftOS-PC** with the real CC APIs: `tools/test.sh [advanced|basic|both]`
  (Linux/CI) or `tools\test.ps1 -ComputerType advanced|basic` (Windows). CI runs both computer
  types on every push.
- Specs live in `tests/*_spec.lua` and return `function(t)`; use `t.it`, `t.ok`, `t.eq`,
  `t.fresh_import()` (modules redirected into `/sandbox`) and `t.with_input()` to type into
  prompts.
- CraftOS-PC does not emulate turtles: turtle logic is tested with a stub `turtle` table, and
  real turtle behaviour must be checked in-game.
- Lint with luacheck (`.luacheckrc`); CI runs it.

## Roadmap

- **Next milestone:** domain auth server; package server (stores packages across many disk
  drives on a wired modem network, which CC mounts as `/disk2`, `/disk3`, ..., and serves them
  over rednet like an apt mirror); remote control for PCs (status panel) and turtles; all
  requiring a domain login token.
- **Later:** uninstall of BlockOS itself, local IPC via custom events, tab completion,
  pocket computer support.
