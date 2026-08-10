#!/bin/bash
#
# Plex Media Server Library Refresh - monitor daemon
#
# Polls a set of configured directories for changes (file/folder added or
# removed - detected via a content signature, not just top-level mtime, so
# changes in subfolders are caught too). Once a directory has been quiet
# for SETTLE_SECONDS (no further changes detected), triggers a scoped Plex
# library refresh for that directory's configured section.
#
# Deliberately polling-based rather than inotify-based: Unraid does not
# ship inotify-tools by default, and this avoids requiring an extra
# package (e.g. via NerdPack) just for the plugin to function out of the box.

set -u

# See rc.plexlibraryrefresh for why this is set explicitly.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

CONFIG_DIR="${PLR_CONFIG_DIR:-/boot/config/plugins/plexlibraryrefresh}"
STATE_DIR="${PLR_STATE_DIR:-/var/lib/plexlibraryrefresh}"
# Per-directory change-tracking state lives on the flash drive (under the
# same persistent location as settings), NOT in $STATE_DIR - /var/lib is
# rebuilt fresh on every Unraid boot (and possibly on plugin reinstalls),
# so a daemon restart would otherwise have no memory of "I already know
# this folder, nothing's changed" and would treat the very first
# observation of every watched directory as a fresh change - firing one
# unwarranted refresh per directory on every restart, confirmed as the
# actual cause of exactly that symptom in testing. The write volume here
# is small (a few dozen bytes, only on an actual signature change or
# quiet-poll increment, not every single poll) so this isn't a meaningful
# flash-wear concern.
STATE_PERSIST_DIR="$CONFIG_DIR/state"
CONFIG_FILE="$CONFIG_DIR/settings.cfg"
DIRS_FILE="$CONFIG_DIR/directories.cfg"
LOG_FILE="$STATE_DIR/monitor.log"
PID_FILE="$STATE_DIR/monitor.pid"

mkdir -p "$STATE_DIR" "$STATE_PERSIST_DIR"

log() {
    local level="$1"; shift
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
    echo "$line" >> "$LOG_FILE"
    # Trim only occasionally (once it's noticeably over the cap), not on
    # every single call - "Change detected" can fire every poll cycle for
    # the full duration of an active download, potentially hours, and a
    # full read+rewrite of the log on every one of those calls is wasted
    # work. wc -l is a cheap linear count; the actual rewrite (the
    # expensive part) only happens roughly once every ~200 lines.
    local n
    n="$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)"
    if [ "${n:-0}" -gt 2200 ] 2>/dev/null; then
        tail -n 2000 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

# ---------------------------------------------------------------- config

load_settings() {
    PLEX_URL=""
    PLEX_TOKEN=""
    POLL_SECONDS=15
    SETTLE_SECONDS=20
    VERIFY_SSL=1
    PLUGIN_ENABLED=1
    # shellcheck disable=SC1090
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
}

# directories.cfg format: one entry per line, pipe-delimited:
#   <path>|<plex_section_id>|<enabled 0/1>|<plex_path>
# plex_path is optional - if blank, the local path is sent to Plex
# as-is. Set it whenever Plex runs in its own container with different
# volume mounts (very likely) - it needs the path exactly as ITS OWN
# library section has it configured, not this Unraid host's raw path.
# Blank lines and lines starting with # are ignored.
load_directories() {
    WATCH_PATHS=()
    WATCH_SECTIONS=()
    WATCH_PLEX_PATHS=()
    [ -f "$DIRS_FILE" ] || return
    while IFS='|' read -r path section enabled plex_path; do
        [ -z "$path" ] && continue
        case "$path" in \#*) continue ;; esac
        [ "$enabled" = "0" ] && continue
        WATCH_PATHS+=("$path")
        WATCH_SECTIONS+=("$section")
        WATCH_PLEX_PATHS+=("${plex_path:-$path}")
    done < "$DIRS_FILE"
}

# ---------------------------------------------------------------- plex api

plex_curl_opts=()

build_curl_opts() {
    plex_curl_opts=(-s -m 15)
    if [ "$VERIFY_SSL" != "1" ]; then
        plex_curl_opts+=(-k)
    fi
}

# Pure-bash URL-encoding, matching Python's urllib.parse.quote() defaults
# (verified byte-for-byte identical output across spaces, parens, &, #,
# and multi-byte UTF-8 characters) - avoids spawning a full Python
# interpreter just to encode a path string on every refresh.
urlencode() {
    local s="$1" c i out=""
    for (( i=0; i<${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_/-]) out+="$c" ;;
            *) printf -v hex '%%%02X' "'$c"
               out+="$hex" ;;
        esac
    done
    printf '%s' "$out"
}

plex_refresh_path() {
    local section_id="$1"
    local path="$2"
    if [ -z "$PLEX_URL" ] || [ -z "$PLEX_TOKEN" ]; then
        log WARN "Plex URL/token not configured - skipping refresh for $path"
        return 1
    fi
    local encoded_path
    encoded_path="$(urlencode "$path")"
    local url="${PLEX_URL%/}/library/sections/${section_id}/refresh?path=${encoded_path}&X-Plex-Token=${PLEX_TOKEN}"
    local http_code
    http_code="$(curl "${plex_curl_opts[@]}" -o /dev/null -w '%{http_code}' "$url")"
    if [ "$http_code" = "200" ]; then
        log INFO "Triggered Plex refresh for section $section_id, path: $path"
        return 0
    else
        log ERROR "Plex refresh failed for section $section_id, path: $path (HTTP $http_code)"
        return 1
    fi
}

# ---------------------------------------------------------------- signatures

# A cheap content signature for a directory tree: path + size + mtime for
# every entry INSIDE it, hashed. Cheap enough to run every poll cycle even
# for large libraries, and changes (add/remove/modify anywhere in the
# tree) reliably change the hash.
#
# -mindepth 1 excludes the watched directory itself from the signature -
# without it, `find` includes the directory's own entry, so for an EMPTY
# folder the entire signature was based solely on that directory's own
# mtime. On Unraid's /mnt/user (a FUSE-based union filesystem), that
# mtime can change from things unrelated to actual content - mover runs,
# cache activity, etc. - triggering false "change detected" events (and
# eventually a pointless refresh) for a folder nothing was ever added to.
# Confirmed directly: touching only the directory's own metadata changed
# the old signature with zero files involved.
dir_signature() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        echo "MISSING"
        return
    fi
    find "$dir" -mindepth 1 -printf '%p|%s|%T@\n' 2>/dev/null | sort | md5sum | awk '{print $1}'
}

state_file_for() {
    # Ephemeral, frequently-updated settle-tracking (current signature,
    # when it last changed, how many consecutive quiet polls) - lives in
    # $STATE_DIR (/var/lib, RAM-backed, rebuilt on every boot). This is
    # fine to lose on a restart: worst case, a folder that was mid-settle
    # just re-settles from scratch, a few seconds of extra delay, not a
    # functional problem. Keeping this OUT of the flash-backed location
    # matters because it can be written on every single poll cycle for
    # the full duration of an active, frequently-changing download -
    # potentially hours of continuous writes.
    local dir="$1"
    local safe
    safe="$(echo "$dir" | md5sum | awk '{print $1}')"
    echo "$STATE_DIR/sig_${safe}.state"
}

fired_file_for() {
    # The ONE piece of state that actually needs to survive a reboot:
    # which content signature was last successfully refreshed for. This
    # is what stops a restart from re-firing on unchanged content (the
    # original bug this whole persistence mechanism exists to fix) - and
    # it's written far less often, only at the moment of an actual fire,
    # not on every poll/every detected change. Small, infrequent writes,
    # appropriate for the flash drive.
    local dir="$1"
    local safe
    safe="$(echo "$dir" | md5sum | awk '{print $1}')"
    echo "$STATE_PERSIST_DIR/fired_${safe}.state"
}

# ---------------------------------------------------------------- incomplete-download detection

# Hard veto on top of the settle timer: even once a directory's content
# signature has looked unchanged for SETTLE_SECONDS, a large multi-part
# download (many separate .rXX archive parts, for example) can have
# natural pauses between individual file completions - waiting for peers,
# verifying a piece, etc. - that exceed the settle window, making it look
# "done" when it isn't. If any of these common still-downloading marker
# files exist anywhere in the tree, refuse to fire regardless of how long
# the timer says it's been quiet.
has_incomplete_markers() {
    local dir="$1"
    find "$dir" \( \
        -iname '*.!qb' -o \
        -iname '*.part' -o \
        -iname '*.!ut' -o \
        -iname '*.crdownload' -o \
        -iname '*.downloading' -o \
        -iname '*.bc!' -o \
        -iname '*.dctmp' -o \
        -iname '*.opdownload' \
    \) -print -quit 2>/dev/null
}

# The stronger, more general check: rather than relying on filename
# conventions (which only help for downloaders that use them), directly
# ask the OS whether any process currently has a file open under this
# tree. This catches ANY still-in-progress writer regardless of what's
# doing the writing - a torrent client, but just as importantly a plain
# file copy (e.g. another tool moving a large multi-GB release into this
# same library folder), which has no "incomplete" marker at all and would
# otherwise be invisible to the check above. Only run right before an
# actual fire (not every poll), since it's more expensive than the
# signature hash.
has_open_writers() {
    local dir="$1"
    if command -v lsof >/dev/null 2>&1; then
        # Only WRITE-mode file descriptors count as "still being written
        # to". lsof's FD column ends in 'w' (write-only) or 'u'
        # (read+write) for those; 'r' (read-only) is completely normal
        # for already-finished content being seeded/shared/played -
        # qBittorrent seeding, AirDC++ sharing, and Plex itself reading
        # or scanning a file all hold it open read-only, essentially all
        # the time for anything in an actively-shared library. Treating
        # read-only opens as "still in progress" would mean this almost
        # never clears on a normal setup.
        timeout 10 lsof +D "$dir" 2>/dev/null | awk '$4 ~ /^[0-9]+[wu]$/' | grep -m1 .
        return
    fi
    if command -v fuser >/dev/null 2>&1; then
        # Cruder fallback, only used if lsof isn't available at all:
        # fuser's simple invocation can't reliably distinguish read from
        # write access across implementations, so this may be overly
        # conservative (could delay a refresh) on a folder with actively
        # shared/seeded content. Install/ensure lsof is available for
        # accurate detection - this is a degraded fallback, not the
        # intended primary path.
        local f
        while IFS= read -r -d '' f; do
            if fuser "$f" >/dev/null 2>&1; then
                echo "$f (fuser fallback - can't confirm write vs read access)"
                return
            fi
        done < <(timeout 10 find "$dir" -type f -print0 2>/dev/null)
        return
    fi
    # Neither tool available - can't check, don't block on this signal alone.
}

# ---------------------------------------------------------------- main loop

log INFO "Monitor daemon starting (pid $$)"
echo $$ > "$PID_FILE"

trap 'log INFO "Monitor daemon stopping"; rm -f "$PID_FILE"; exit 0' TERM INT

_plr_was_disabled=0

while true; do
    load_settings

    # "Enable plugin" lets the process keep running (so Start/Stop stay
    # meaningful as separate controls) while pausing all actual watching/
    # refreshing - a lighter-weight pause than stopping the daemon
    # entirely. Logged only on the transition into/out of the disabled
    # state, not every cycle, to avoid spamming the log while paused.
    if [ "$PLUGIN_ENABLED" != "1" ]; then
        if [ "$_plr_was_disabled" != "1" ]; then
            log INFO "Plugin disabled - idling until re-enabled."
            _plr_was_disabled=1
        fi
        sleep "${POLL_SECONDS:-15}"
        continue
    fi
    if [ "$_plr_was_disabled" = "1" ]; then
        log INFO "Plugin re-enabled - resuming."
        _plr_was_disabled=0
    fi

    load_directories
    build_curl_opts

    now="$(date +%s)"

    for i in "${!WATCH_PATHS[@]}"; do
        dir="${WATCH_PATHS[$i]}"
        section="${WATCH_SECTIONS[$i]}"
        plex_path="${WATCH_PLEX_PATHS[$i]}"
        state_file="$(state_file_for "$dir")"
        fired_file="$(fired_file_for "$dir")"

        current_sig="$(dir_signature "$dir")"

        prev_sig=""
        prev_changed_at=""
        quiet_polls=0
        if [ -f "$state_file" ]; then
            # shellcheck disable=SC1090
            source "$state_file"
        fi
        fired_sig=""
        if [ -f "$fired_file" ]; then
            # shellcheck disable=SC1090
            source "$fired_file"
        fi

        if [ "$current_sig" != "$prev_sig" ]; then
            # A real change - reset the elapsed-time clock and the
            # consecutive-quiet-poll counter. Ephemeral write only.
            {
                echo "prev_sig='$current_sig'"
                echo "prev_changed_at=$now"
                echo "quiet_polls=0"
            } > "$state_file"
            log DEBUG "Change detected under: $dir"
            continue
        fi

        # Unchanged from last poll. If we've ALREADY successfully fired a
        # refresh for this exact content signature, there is nothing to
        # do - stop here without touching quiet_polls/prev_changed_at at
        # all. This is the critical guard: without it, a fire would
        # otherwise re-arm its own timer (by resetting prev_changed_at to
        # the firing moment) and the settle-then-fire cycle would just
        # repeat forever on a fixed interval even with a completely
        # static, unchanged folder - confirmed as a real bug in testing,
        # not just a theoretical concern.
        if [ "$current_sig" = "$fired_sig" ]; then
            continue
        fi

        quiet_polls=$(( quiet_polls + 1 ))
        elapsed=$(( now - prev_changed_at ))

        # Firing requires ALL of:
        #  1. elapsed >= SETTLE_SECONDS
        #  2. at least 2 INDEPENDENT quiet polls, not just 1 - guards
        #     against SETTLE_SECONDS being configured close to (or
        #     smaller than) POLL_SECONDS, which would otherwise let a
        #     single quiet poll satisfy the elapsed check trivially.
        #  3. no incomplete-download marker present (helps for
        #     downloaders that use one)
        #  4. no process currently has a file open FOR WRITING under this
        #     tree (read-only opens - seeding, sharing, playback/scanning
        #     - are ignored and never block a refresh)
        if [ "$elapsed" -ge "$SETTLE_SECONDS" ] && [ "$quiet_polls" -ge 2 ]; then
            marker="$(has_incomplete_markers "$dir")"
            writer="$([ -z "$marker" ] && has_open_writers "$dir")"
            if [ -n "$marker" ]; then
                log DEBUG "Still waiting under $dir - incomplete-download marker present: $marker"
                { echo "prev_sig='$current_sig'"; echo "prev_changed_at=$prev_changed_at"; echo "quiet_polls=$quiet_polls"; } > "$state_file"
            elif [ -n "$writer" ]; then
                log DEBUG "Still waiting under $dir - a process still has a file open there: $writer"
                { echo "prev_sig='$current_sig'"; echo "prev_changed_at=$prev_changed_at"; echo "quiet_polls=$quiet_polls"; } > "$state_file"
            else
                if [ -n "$section" ]; then
                    plex_refresh_path "$section" "$plex_path"
                else
                    log WARN "No Plex section configured for $dir - skipping refresh."
                fi
                # The ONE flash write per fire event - records that THIS
                # signature has now been refreshed, which is what stops
                # a future restart from re-firing on the same unchanged
                # content.
                echo "fired_sig='$current_sig'" > "$fired_file"
                { echo "prev_sig='$current_sig'"; echo "prev_changed_at=$now"; echo "quiet_polls=0"; } > "$state_file"
            fi
        else
            # Not ready to fire yet - persist the incremented quiet-poll
            # count so it keeps accumulating across cycles. Ephemeral
            # write only.
            { echo "prev_sig='$current_sig'"; echo "prev_changed_at=$prev_changed_at"; echo "quiet_polls=$quiet_polls"; } > "$state_file"
        fi
    done

    sleep "$POLL_SECONDS"
done
