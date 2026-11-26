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
| `update` | Upgrade from the latest release (`--tag`, `--disk`, `--check`, `--make-disk`) |
| `useradd`, `userdel`, `passwd` | Manage local accounts |
| `logout` | Log out (closes all tabs) |

## Optional packages

The base install only contains what a device needs to join the network. Extra software comes
as optional packages, installed from a release (`pkg install <name>`) or from an add-on disk
(`pkg install <name> --disk`). `pkg make-disk <name>` writes an add-on disk for other
computers.

## A domain (one login for all computers)

1. On a computer that will do nothing else: `pkg install domain-controller`, then `dcpromo`
   (choose a domain name like `home` and the first domain admin).
2. On every other computer or turtle: `pkg install domain`, then `domain join home` and log in
   with a domain admin when asked.
3. Log in with domain accounts from then on. Local accounts still work as `.\name`, for example
   when the controller is down.
4. Manage users, groups, computers and service records with `dsa` (full screen) or `domain`.

## A package server

On a computer with disk drives (attach as many as you like with wired modems):
`pkg install pkg-server`, then `pkgserver import --latest`. Register it once with
`domain dns add pkg <hostname>`; other computers then install with `pkg install <name> --server`.
`pkgserver allow <name> <group>` limits a package to a group.

## Recovery

If BlockOS keeps failing to start, it rolls back to the previous version by itself. You can
also put the install disk in and reboot: the menu offers **Boot**, **Upgrade/Reinstall**,
**Safe mode** (a plain CraftOS shell) and **Roll back**. `update --make-disk` writes an install
disk from a running BlockOS computer.

## Development

See [CLAUDE.md](CLAUDE.md) for the architecture, code style and conventions. Tests run in CI
inside the [CraftOS-PC](https://www.craftos-pc.cc) emulator (`tools/test.sh`). Pushing a `v*` tag
builds and publishes a release.
