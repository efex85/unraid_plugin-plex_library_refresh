# Plex Media Server Library Refresh (Unraid plugin)

Watches a set of directories you choose, and when files inside them settle
after a change (something added or removed), triggers a scoped Plex
library refresh for that directory - no full-library rescan.

This is a **native Unraid plugin**, not a Docker container: it installs
directly into Unraid's OS and shows up under Settings in the webGUI.

> **Note on testing:** individual pieces (the monitor daemon's
> change-detection/debounce logic, the settings page's save/load handling,
> the service start/stop lifecycle, and the `.plg` packaging itself) are
> unit-tested in isolation, but this hasn't been fully exercised inside a
> live Unraid webGUI - I don't have an Unraid instance available to verify
> against. If anything looks or behaves oddly after installing, tell me
> exactly what you see and I'll fix it.

## What's in this package

- `plexlibraryrefresh.plg` - the plugin installer. This is the file to
  install (see below) - everything else gets written to disk from inside it.
- `manual-install/` - the same three files (`PlexLibraryRefresh.page`,
  `monitor.sh`, `rc.plexlibraryrefresh`) as plain files, in case you'd
  rather copy them into place yourself instead of using the `.plg`
  installer, or want to inspect exactly what the plugin does before
  installing it.

## Installing

### Recommended: install from the local file via SSH

This avoids needing to host the `.plg` anywhere:

1. Copy `plexlibraryrefresh.plg` onto your Unraid flash drive, e.g. into
   `/boot/config/plugins/plexlibraryrefresh.plg` (drag it into the `flash`
   share from your PC, or `scp` it over).
2. SSH into Unraid and run:
   ```bash
   plugin install /boot/config/plugins/plexlibraryrefresh.plg
   ```
3. Go to **Settings → User Utilities → Plex Library Refresh** in the webGUI.

### Alternative: install via the Plugins tab

If you'd rather use the GUI's **Plugins → Install Plugin** URL field,
you'll need to host the `.plg` file somewhere fetchable over HTTP first
(e.g. push it to a GitHub repo and use the raw file URL), then paste that
URL in. The SSH method above is simpler if you don't already have
somewhere to host it.

## Configuring

On the **Settings → Plex Library Refresh** page:

1. **Enable plugin** (top checkbox) - controls whether the daemon
   actively watches anything and talks to Plex at all. Uncheck and Save
   to pause everything without stopping the daemon process or
   uninstalling - useful if you want to temporarily disable it (e.g.
   during Plex maintenance) without losing your configured directories.
   The daemon process keeps running either way, so Start/Stop below stay
   meaningful as separate, lower-level controls.
2. Enter your **Plex URL** (e.g. `http://10.0.20.5:32400`) and **Plex
   token**. Click **Test connection** - this also lists your Plex
   libraries, their section IDs, and **the exact path(s) Plex itself has
   configured for each one** - important for step 3.
3. Under **Watched directories**, add one row per folder you want
   monitored: the exact path as *this Unraid server* sees it (e.g.
   `/mnt/user/Share/TV.1080p`), the Plex library section ID it belongs
   to, and - **if Plex runs in its own container** (very likely) - its
   "Plex's own path for this folder" field. Plex needs the path exactly
   as *it* has configured for that library, which is almost certainly
   different from this Unraid server's raw path if Plex has its own
   Docker volume mounts. Leave it blank only if you've confirmed Plex
   sees the identical path (e.g. Plex isn't containerized, or its mounts
   happen to match exactly) - otherwise the refresh call will report
   success (HTTP 200) while doing nothing, since Plex silently doesn't
   recognize a path outside its own configured locations. Use the paths
   shown in Test connection (step 2) as the value to enter here.
4. **Poll interval** - how often the daemon checks for changes (default 15s).
5. **Settle time** - how long a directory must be quiet (no further
   changes) before a refresh fires (default 20s). These defaults are
   deliberately short - the main protection against firing mid-download
   is the open-file-handle check (see "How it decides something changed"
   below), not a long timer. Only raise these if your setup can't use
   that check (e.g. `lsof`/`fuser` unavailable, or a filesystem layer
   that doesn't expose open-file info correctly) and you need to fall
   back to timing alone as the primary safeguard.
6. **Hide debug messages in Recent activity** - unchecked by default.
   Debug-level messages (change detections, incomplete-marker waits) can
   be frequent during an active large download; this only affects what's
   *shown* here, everything is still written to the underlying log
   either way.
7. Click **Save settings**, then **Start** the daemon if it isn't already
   running (it starts automatically on install and on every boot).

The **Recent activity** panel on that page shows the daemon's own log -
change detections, refreshes triggered, and any errors - useful for
confirming it's actually working without waiting for a real download.

## How it decides something changed

Every poll cycle, each watched directory gets a signature (every file's
path, size, and modified time, hashed together) compared against its
previous signature. Any difference - a file added, removed, renamed, or
modified anywhere in the tree, not just the top level - counts as a
change and resets that directory's settle timer.

The daemon also remembers which exact content signature it last
successfully refreshed for, and never fires again for a repeat
observation of that same unchanged signature - only a genuinely new one
(a real change) re-arms it. Without this, a fire would otherwise look
indistinguishable from a fresh change from the state machine's point of
view, and the settle-then-fire cycle would repeat indefinitely on a fixed
interval even with a completely static, unchanged folder - this was a
real bug caught in testing (nine refreshes in twenty seconds for a
directory with a single change and nothing further), not just a
theoretical concern, so if you were seeing periodic refreshes with
nothing actually changing, this is why.

A refresh only fires once **all** of the following are true:

1. At least `SETTLE_SECONDS` have passed since the last detected change.
2. At least **2 independent poll cycles** have observed no change - not
   just 1. This matters if `SETTLE_SECONDS` ends up close to (or smaller
   than) `POLL_SECONDS`: without this, a single quiet poll would satisfy
   the elapsed-time check trivially, giving almost no real debounce
   protection. Requiring 2 independent observations closes that gap
   regardless of how the two settings relate to each other.
3. No common "still downloading" marker file (`.part`, `.!qb`, `.!ut`,
   `.crdownload`, `.downloading`, `.bc!`, `.dctmp`, `.opdownload`) exists
   anywhere in the tree.
4. **No process currently has any file in the tree open for writing**
   (checked via `lsof`, falling back to a cruder `fuser`-based check if
   `lsof` isn't available) - this is the strongest signal and works
   regardless of what's doing the writing, not just downloaders that use
   a marker naming convention. Deliberately checks **write** access only
   (`lsof`'s FD column ending in `w` or `u`), not read access - qBittorrent
   seeding, AirDC++ sharing, and Plex itself reading or scanning a file
   all hold it open read-only essentially all the time for anything in an
   actively-used library, so treating any open handle as "still in
   progress" would mean this almost never clears on a normal setup where
   finished content stays open for sharing/playback. Only a genuine write
   handle blocks. Checked right before an actual fire, not every poll,
   since it's more expensive than the signature hash.

These matter for large multi-part downloads specifically: many separate
archive parts (`.r00`, `.r01`, ...), or a single very large file being
copied in by another tool, can have natural pauses - waiting on peers,
verifying a piece, flushing to disk - that are longer than a short settle
window, making the folder look "done" when it isn't. Since Plex can't
extract a multi-part archive until every part has arrived, firing early
means Plex sees (and may cache as "missing") an incomplete file. Checks
3 and 4 catch this even when the settle timer alone wouldn't - check 4 in
particular doesn't depend on knowing anything about what's writing the
files, so it should catch this regardless of whether it's a torrent
client, another Docker container moving files in, or anything else.

This is deliberately polling-based rather than using `inotify` - Unraid
doesn't ship `inotify-tools` by default, and this avoids requiring an
extra package just for the plugin to work out of the box. The trade-off
is that changes are noticed on the next poll cycle, not instantly - fine
for this use case, since Plex doesn't need to know about a new file the
instant it lands, just before someone goes looking for it.

## Files this plugin manages

| Path | Purpose |
|---|---|
| `/boot/config/plugins/plexlibraryrefresh/settings.cfg` | Plex URL/token/timing settings (persists across reboots) |
| `/boot/config/plugins/plexlibraryrefresh/directories.cfg` | Watched directories and their Plex section IDs |
| `/boot/config/plugins/plexlibraryrefresh/state/` | Per-directory change-tracking state (persists across reboots - see note below) |
| `/var/lib/plexlibraryrefresh/monitor.log` | Activity log (also shown on the settings page) |
| `/var/lib/plexlibraryrefresh/monitor.pid` | PID file for the running daemon |
| `/usr/local/emhttp/plugins/plexlibraryrefresh/` | The webGUI page and daemon script (rebuilt from the plugin on every boot) |
| `/etc/rc.d/rc.plexlibraryrefresh` | Service control script (`start`/`stop`/`restart`/`status`) |

The per-directory state (what a folder's content looked like the last
time it was checked) deliberately lives under `/boot`, not `/var/lib` -
`/var/lib` is rebuilt fresh on every boot, so without this a daemon
restart (reboot, a plugin update, or just clicking Restart) would have no
memory of "I already know this folder, nothing's changed," and would
fire one unwarranted refresh per watched directory every time the daemon
starts - confirmed as a real, reproducible symptom, not just a
theoretical concern. The state itself is tiny (a few dozen bytes per
directory, written only on an actual change or settle-progress update,
not every single poll), so this isn't a meaningful flash-wear concern.
If you're updating from a version before this fix, expect **one**
unwarranted refresh per watched directory the first time you start the
new version, as it establishes a fresh baseline in the new location -
after that, restarts should no longer cause spurious refreshes.

Settings, directories, and state live under `/boot`, logs under
`/var/lib`, so your configuration and tracking state survive reboots
even though the webGUI page/daemon script themselves get rewritten fresh
from the plugin on every boot (standard
Unraid plugin behavior, since most of the filesystem isn't persistent).

## Uninstalling

Remove it from **Plugins** in the webGUI, or via SSH:
```bash
plugin remove plexlibraryrefresh
```
This stops the daemon and removes the webGUI page/service script, but
**deliberately leaves your settings and logs in place** (`/boot/config/plugins/plexlibraryrefresh`
and `/var/lib/plexlibraryrefresh`) in case you reinstall later. Delete
those manually too if you want a fully clean removal:
```bash
rm -rf /boot/config/plugins/plexlibraryrefresh /var/lib/plexlibraryrefresh
```

## Performance and resource use

After a lot of iteration, a self-review pass found a few things worth
tightening up - two genuine resource-usage issues and one dead-weight
cleanup:

- **Flash writes reduced to one per actual refresh, not one per poll.**
  Per-directory tracking state is now split: the frequently-changing part
  (current signature, when it last changed, how many quiet polls in a
  row) lives in the RAM-backed `/var/lib` location and can be written on
  every poll cycle for as long as something is actively changing, with no
  flash-wear cost at all. Only the one fact that actually needs to
  survive a reboot - "which content signature was last successfully
  refreshed" - is written to the flash-backed config location, and only
  at the moment a refresh actually fires (which is rare, by design).
  Previously all of this lived on the flash-backed path, meaning an
  hours-long active download could mean continuous flash writes for its
  entire duration.
- **Log trimming no longer rewrites the whole file on every line.**
  Previously every single log call re-read and rewrote the entire log
  file to keep it under 2000 lines, including during bursts of frequent
  `[DEBUG]` activity. It now only trims in batches (roughly every 200
  lines past the cap), so the common case is a plain append.
- **No more spawning a Python interpreter to URL-encode a path.** Each
  refresh previously shelled out to `python3` just to percent-encode the
  path sent to Plex. Replaced with a small pure-bash equivalent, verified
  to produce byte-for-byte identical output to Python's `urllib.parse.quote()`
  across spaces, parentheses, `&`, `#`, and multi-byte UTF-8 characters.
- **Removed leftover debug logging from an earlier investigation.** Every
  page load (including just viewing the settings page) used to write to
  both syslog and the log file unconditionally - useful while chasing an
  earlier CSRF issue, pure noise now that it's resolved. Action-triggered
  logging (Save, Test connection, Start/Stop/Restart) is unaffected and
  still there.

What's inherent to the design and not really fixable without adding a
dependency: computing each directory's content signature means walking
its file tree and `stat`-ing every entry, every poll cycle - there's no
way around some form of periodic re-scanning without `inotify` (not
available on stock Unraid, see below). For a very large library polled
frequently, this is the actual CPU/IO cost that exists day to day; if it
ever matters for your setup, raising the poll interval for directories
that don't change often is the direct way to reduce it.

## Troubleshooting

- **A refresh fires for every watched directory right after the daemon
  starts, even though nothing changed.** Fixed - see the note under
  "Files this plugin manages" above. If you're still seeing this after
  updating and past the expected one-time transition, check whether
  something is deleting `/boot/config/plugins/plexlibraryrefresh/state/`
  (a custom flash-backup exclusion, a cache-clearing script, etc.).
- **A refresh fires for a folder even though nothing in it actually
  changed - including a completely empty folder.** Confirmed and fixed:
  the content signature previously included the watched directory's own
  entry (mtime/size), not just its contents. For an empty folder, that
  meant the *entire* signature was based solely on the directory's own
  metadata - and on Unraid's `/mnt/user` (a FUSE-based union filesystem),
  that can change from things unrelated to actual content (mover runs,
  cache activity, etc.), triggering a false "change detected" and
  eventually a pointless refresh. Reproduced directly (touching only the
  directory's own metadata changed the signature with zero files
  involved) and fixed by excluding the directory's own entry from the
  signature, considering only what's actually inside it.
- **Refresh logs "Triggered Plex refresh" (HTTP 200), but the content
  never actually shows up in Plex.** This means the `path` sent to Plex
  doesn't correspond to anything in that library's own configuration -
  Plex accepts the request (200 OK) but has nothing to do, since the
  path is meaningless from its point of view. Almost always means Plex
  runs in its own container with different volume mounts than this
  Unraid server sees for the same folder. Fix: set the **"Plex's own
  path for this folder"** field for that directory (see Configuring,
  step 3) - use Test connection to see exactly what path(s) Plex has
  configured for each library.
- **Status shows "running" no matter what you click.** Confirmed and
  fixed: `pgrep -f` matches against the *entire command line* of every
  process, including the transient shell processes PHP/this script spawn
  to run `pgrep` itself - since that command line literally contains the
  search pattern as text, it was matching itself, always. Verified via
  direct testing that this made the status check return "running" even
  with nothing actually running. Fixed with a standard trick: bracketing
  one character of the pattern (`[m]onitor.sh` instead of `monitor.sh`)
  - functionally identical for matching the real process, but no longer
  matches `pgrep`'s own invocation, since that literally contains the
  bracket characters as text rather than as regex syntax. Verified
  end-to-end: status now correctly flips to "Stopped" after a real stop,
  and Start/Stop/Restart do exactly what they say.
- **Start/Stop/Restart buttons don't do anything.** Likely a `PATH`
  issue: PHP's shell functions often run with a much more restricted
  `PATH` than an interactive SSH session, so bare commands like
  `pgrep`/`xargs`/`nohup` inside the service script could silently fail
  to be found. Both `rc.plexlibraryrefresh` and `monitor.sh` now
  explicitly set a full standard `PATH` at the top rather than relying on
  the caller's environment. The button messages also now show the
  service script's actual output (e.g. "Start: Started (pid 1234).")
  instead of a generic "requested" message, and it's logged to syslog too
  - if it's still not working after updating, that output/log line should
  say why (e.g. permission denied, script not found).
- **"Connection failed (HTTP 0)".** HTTP `0` means cURL never got a
  response at all (not a real HTTP status from Plex) - could be DNS
  failure, connection refused/timeout, or an SSL handshake failure. Fixed
  two things: (1) `CURLOPT_SSL_VERIFYHOST` is now disabled alongside
  `CURLOPT_SSL_VERIFYPEER` - Plex's self-signed certificate is issued for
  a `*.plex.direct` hostname, not a raw IP, so hostname verification
  failed even with peer verification off when connecting by IP (the
  normal way to reach a local Plex server); (2) the actual cURL error
  message is now shown directly (e.g. "Couldn't connect to server",
  "SSL certificate problem") instead of just the unhelpful HTTP 0 - also
  logged to syslog under the `plexlibraryrefresh` tag for anything not
  obvious from the on-page message.
- **CSRF is now logged but never enforced.** After three different fixes
  each failed in a different way on this specific Unraid install (a
  custom token that didn't match Unraid's real mechanism; the documented
  `$var['csrf_token']` pattern where the field's key went missing from
  `$_POST` entirely; a JS `fetch()`-based workaround that stopped the
  request from reaching this script at all), the token check no longer
  blocks anything - Save/Test/Start/Stop/Restart all proceed regardless
  of whether it matches. Access control relies on Unraid's own webGUI
  login/session boundary, which is the meaningful protection for a
  single-admin home NAS tool. The token is still loaded and logged (via
  syslog, tag `plexlibraryrefresh`) in case the underlying cause is worth
  chasing down later - it just doesn't gate functionality anymore.
- **CSRF field silently missing from the actual submission, not just
  empty.** Confirmed via syslog tracing on a real Unraid 7.3.2 install:
  the `csrf_token` field wasn't merely empty, its *key* was entirely
  absent from `$_POST` while every other field submitted fine. The cause
  wasn't ad-blocking (confirmed not in use) and my own rendered HTML is
  provably valid on its own - the most likely explanation is something in
  how Unraid's own page chrome wraps plugin content interacting badly
  with this one specific field, though the exact mechanism remains
  unconfirmed. Rather than keep chasing an unknown cause, form submission
  now goes through JavaScript that captures the token in a variable at
  page load and force-sets it into the submitted data at the moment of
  submission, bypassing the DOM element (and whatever affects it)
  entirely for the actual network request. This could not be tested in a
  real browser here (sandbox network restrictions blocked downloading
  one) - the JS syntax and the server-side handling of the exact
  encoding it uses were verified directly, but the real-browser behavior
  needs your confirmation.
- **CSRF token restored, using the documented pattern.** Earlier versions
  of this plugin went through two wrong turns: first a custom token that
  didn't match Unraid's real mechanism, then removing the token entirely
  (which likely made things worse, since Unraid documents CSRF as
  mandatory for all POST submissions and may reject requests missing it
  before a plugin's own code even runs). The current version uses the
  documented pattern directly - `$var['csrf_token']`, sourced from
  `/var/local/emhttp/var.ini` - matching Unraid's own plugin development
  documentation.
- **Still seeing issues after updating?** Watch the log live while you
  test:
  ```bash
  tail -f /var/log/syslog | grep plexlibraryrefresh
  ```
  Every request now logs each step (page load, CSRF token loaded and its
  length, POST received with the posted vs. expected token prefixes) -
  this should make it possible to see exactly where things diverge,
  rather than continuing to guess.
- **Blank white screen on Save/Test/Start/Stop.** Should now show an
  actual error message on the page (and in the log above) instead of
  going blank, if the cause is a PHP-level error. If it's still
  completely blank with nothing at all in the syslog output above,
  that would point to something intercepting the request before it
  reaches this plugin's code at all - worth checking Unraid's own
  system log (Tools → System Log in the webGUI) around the time of the
  blank response for anything unrelated to this plugin by name.
- **If you're updating from a version before this note existed:** an
  earlier version of this plugin included a custom CSRF token on its
  forms, which caused every save/start/stop action to fail with "Security
  token mismatch" on some Unraid installs (something in that Unraid
  install's own page chrome interfered with a hidden field named
  `csrf_token`). That token has been removed entirely - access control
  relies on Unraid's own webGUI login/session boundary, which is the
  meaningful protection for a single-admin home NAS tool. If you were
  stuck on that error, reinstalling with the current `.plg` should fix it
  outright. If a Stop request was silently blocked by that bug, you may
  have ended up with more than one monitor process running - the current
  version's Stop/Restart kill *every* matching process (not just the one
  in the PID file), so a single Stop or Restart click cleans that up too.
- **Daemon shows "stopped" after install.** Check
  `/var/lib/plexlibraryrefresh/monitor_stdout.log` for a startup error, or
  try `/etc/rc.d/rc.plexlibraryrefresh start` directly via SSH to see the
  output live.
- **"Connected. 0 libraries found."** - the token/URL are reaching Plex
  fine, but check the token has access to any libraries at all (e.g. it's
  a managed/limited user's token rather than the server owner's).
- **Refresh never fires.** Check the **Recent activity** log for "Change
  detected under: ..." lines - if those never appear, the daemon likely
  isn't actually watching that path (typo, or a permissions issue
  reading the directory). If changes ARE detected but no refresh follows,
  check the Plex URL/token are still correct via Test connection.
- **Something about the settings page itself looks broken** (styling,
  missing menu entry, PHP errors) - since this wasn't tested against a
  live Unraid webGUI, this is the most likely spot for a real bug. Tell
  me exactly what you see (a screenshot description, any PHP error text,
  which Unraid version) and I'll fix it directly.
