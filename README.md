# Plex Media Server Library Refresh (Unraid plugin)

Watches a set of directories you choose, and once a directory has settled
after a change (something added or removed), triggers a scoped Plex
library refresh for that directory - no full-library rescan.

This is a native Unraid plugin: it installs
directly into Unraid's OS and shows up under **Settings → User Utilities**.

## What's in this package

- `plexlibraryrefresh.plg` - the plugin installer. This is the file to
  install - everything else gets written to disk from inside it.
- `manual-install/` - the same files as plain copies, in case you'd
  rather inspect or install them manually instead of using the `.plg`.

## Installing

**Recommended - install from the local file via SSH** (no external
hosting needed):

1. Copy `plexlibraryrefresh.plg` onto your Unraid flash drive, e.g. into
   `/boot/config/plugins/plexlibraryrefresh.plg`.
2. SSH into Unraid and run:
   ```bash
   plugin install /boot/config/plugins/plexlibraryrefresh.plg
   ```
3. Go to **Settings → User Utilities → Plex Library Refresh**.

**Alternative:** use the Plugins tab's **Install Plugin** URL field, if
you host the `.plg` somewhere fetchable over HTTP.

## Configuring

1. **Enable plugin** - controls whether the daemon actively watches
   anything. Uncheck and Save to pause everything without stopping the
   daemon or uninstalling.
2. Enter your **Plex URL** and **Plex token**, then **Test connection** -
   this lists your Plex libraries, their section IDs, and the exact
   path(s) Plex itself has configured for each one.
3. Under **Watched directories**, add one row per folder to monitor:
   - The path as *this Unraid server* sees it (e.g. `/mnt/user/Share/TV.1080p`).
   - The Plex library section ID it belongs to.
   - **"Plex's own path for this folder"** - if Plex runs in its own
     container (very likely), it needs the path exactly as *it* has
     configured, which is almost certainly different from this Unraid
     server's raw path. Leave blank only if you've confirmed Plex sees
     an identical path. If this is wrong, refreshes will report success
     (HTTP 200) but do nothing, since Plex doesn't recognize the path.
     Use the paths shown in Test connection as the value.
4. **Poll interval** (default 15s) and **Settle time** (default 20s) -
   how often the daemon checks for changes, and how long a directory must
   stay quiet before a refresh fires. These are short by design; the main
   protection against firing mid-download is the open-file check (see
   below), not a long timer.
5. **Hide debug messages in Recent activity** - unchecked by default.
   Debug messages can be frequent during an active download; this only
   affects what's shown on the page, not what's logged underneath.
6. **Save settings**, then **Start** the daemon if it isn't already
   running.

## How it decides something changed

Each poll, every watched directory gets a signature (every file's path,
size, and modified time, hashed together) compared against its previous
signature. Any difference anywhere in the tree counts as a change and
resets that directory's settle timer.

A refresh only fires once **all** of the following are true:

1. At least **Settle time** has passed since the last detected change.
2. At least **2 independent poll cycles** have observed no change - not
   just one, so a short settle time relative to the poll interval can't
   trivially satisfy the check.
3. No common "still downloading" marker file (`.part`, `.!qb`, `.!ut`,
   `.crdownload`, `.downloading`, `.bc!`, `.dctmp`, `.opdownload`) exists
   anywhere in the tree.
4. No process currently has any file in the tree open **for writing**
   (checked via `lsof`, or a cruder `fuser`-based fallback if `lsof`
   isn't available). Read-only access - qBittorrent seeding, AirDC++
   sharing, Plex itself scanning or playing a file - is ignored and never
   blocks a refresh; only an active write does.

Once a refresh fires for a given piece of content, the daemon remembers
that signature and won't fire again for it - only a genuine subsequent
change re-arms it. That "already refreshed" record is the one thing that
persists across a daemon restart or reboot (stored under `/boot`); the
rest of the tracking state is disposable and just re-establishes itself
after a restart.

This is polling-based rather than `inotify`-based, since Unraid doesn't
ship `inotify-tools` by default. Changes are noticed on the next poll,
not instantly - fine for this use case.

## Files this plugin manages

| Path | Purpose |
|---|---|
| `/boot/config/plugins/plexlibraryrefresh/settings.cfg` | Settings (persists across reboots) |
| `/boot/config/plugins/plexlibraryrefresh/directories.cfg` | Watched directories |
| `/boot/config/plugins/plexlibraryrefresh/state/` | "Already refreshed" record per directory (persists across reboots) |
| `/var/lib/plexlibraryrefresh/monitor.log` | Activity log (shown on the settings page) |
| `/var/lib/plexlibraryrefresh/monitor.pid` | PID file for the running daemon |
| `/usr/local/emhttp/plugins/plexlibraryrefresh/` | webGUI page and daemon script (rebuilt from the plugin on every boot) |
| `/etc/rc.d/rc.plexlibraryrefresh` | Service control script (`start`/`stop`/`restart`/`status`) |

## Uninstalling

Remove it from **Plugins** in the webGUI, or via SSH:
```bash
plugin remove plexlibraryrefresh
```
This leaves your settings in place in case you reinstall later. For a
fully clean removal, also run:
```bash
rm -rf /boot/config/plugins/plexlibraryrefresh /var/lib/plexlibraryrefresh
```

## Performance

- Per-directory state writes to the flash drive only happen once per
  actual refresh (rare, by design), not continuously while something is
  settling - frequent tracking updates live in RAM instead.
- The log trims itself in batches rather than rewriting the whole file
  on every line.
- The main ongoing cost is inherent to polling: each check walks a
  watched directory's file tree. For a very large library, raising the
  poll interval reduces this directly.
  tail -f /var/log/syslog | grep plexlibraryrefresh
  ```
