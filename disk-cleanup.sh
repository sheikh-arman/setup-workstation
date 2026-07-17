#!/usr/bin/env bash
# disk-cleanup.sh - reclaim disk space on any Ubuntu/Debian machine.
#
# Removes only things that are regenerable or already past their retention
# window. Dry run by default; nothing is deleted without --apply.
#
#   disk-cleanup.sh                     # show what would be freed
#   disk-cleanup.sh --apply             # do it
#   disk-cleanup.sh --apply apt snap    # only selected tasks
#   disk-cleanup.sh --list              # list tasks
#   sudo disk-cleanup.sh --apply        # include root-owned tasks
#
# Tasks: apt snap journal logs docker gocache caches trash makeclean
#
# Config: env vars, or a file at /etc/disk-cleanup.conf or
# ${XDG_CONFIG_HOME:-~/.config}/disk-cleanup.conf (sourced as shell).

set -uo pipefail

VERSION=2.0

# --- Configurable knobs (override via env or config file) ---------------------
: "${LOG_ORPHAN_AGE_DAYS:=30}"    # age before an orphaned rotated log is stale
: "${JOURNAL_KEEP:=500M}"         # journald retention after vacuum
: "${SNAP_RETAIN:=}"              # if set (e.g. 2), cap future snap revisions
: "${APT_AUTOREMOVE:=1}"          # 1 = also autoremove orphaned packages
: "${MAKE_CLEAN_DIRS:=}"          # colon-separated parent dirs of Makefile repos
: "${CLEAN_ALL_USERS:=0}"         # 1 = sweep every home dir, not just yours

for cfg in /etc/disk-cleanup.conf "${XDG_CONFIG_HOME:-$HOME/.config}/disk-cleanup.conf"; do
    # shellcheck disable=SC1090
    [ -r "$cfg" ] && . "$cfg"
done

ALL_TASKS=(apt snap journal logs docker gocache caches trash makeclean)

# Cache dirs that are unambiguously regenerable. Names only; resolved under
# each target user's XDG cache dir so this stays portable across machines.
CACHE_NAMES=(
    go-build gopls goimports golangci-lint staticcheck
    JetBrains github-copilot
    google-chrome chromium mozilla
    yarn pip typescript ms-playwright puppeteer electron
    vscode-cpptools bazel
)

# --- Arg parsing --------------------------------------------------------------
APPLY=0
TASKS=()

usage() { sed -n '2,20p' "$0" | sed 's/^# \?//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)      APPLY=1 ;;
        --all-users)  CLEAN_ALL_USERS=1 ;;
        --age)        LOG_ORPHAN_AGE_DAYS="${2:?--age needs days}"; shift ;;
        --journal-keep) JOURNAL_KEEP="${2:?--journal-keep needs size}"; shift ;;
        --make-dir)   MAKE_CLEAN_DIRS="${MAKE_CLEAN_DIRS:+$MAKE_CLEAN_DIRS:}${2:?}"; shift ;;
        --list)       printf '%s\n' "${ALL_TASKS[@]}"; exit 0 ;;
        --version)    echo "disk-cleanup.sh $VERSION"; exit 0 ;;
        -h|--help)    usage; exit 0 ;;
        -*)           echo "unknown flag: $1" >&2; exit 2 ;;
        *)            TASKS+=("$1") ;;
    esac
    shift
done
[ ${#TASKS[@]} -eq 0 ] && TASKS=("${ALL_TASKS[@]}")

for t in "${TASKS[@]}"; do
    printf '%s\n' "${ALL_TASKS[@]}" | grep -qx -- "$t" || {
        echo "unknown task: $t (valid: ${ALL_TASKS[*]})" >&2; exit 2; }
done
wants() { printf '%s\n' "${TASKS[@]}" | grep -qx -- "$1"; }

# --- Privilege handling -------------------------------------------------------
# Three cases: already root, can sudo without a prompt, or neither. Root-only
# tasks degrade to a skip rather than blocking on a password prompt.
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""; HAVE_ROOT=1
elif sudo -n true 2>/dev/null; then
    SUDO="sudo"; HAVE_ROOT=1
else
    SUDO=""; HAVE_ROOT=0
fi

# Under `sudo`, $HOME is /root - so user caches must resolve via SUDO_USER,
# or we would clean root's empty cache and miss the real user's entirely.
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    INVOKING_USER="$SUDO_USER"
else
    INVOKING_USER="$(id -un)"
fi

home_of() { getent passwd "$1" | cut -d: -f6; }

# Users whose caches we clean: just the invoking user, or every human account.
target_users() {
    if [ "$CLEAN_ALL_USERS" = "1" ] && [ "$HAVE_ROOT" = "1" ]; then
        # UID >= 1000 and < 65534 excludes system accounts and `nobody`.
        getent passwd | awk -F: '$3>=1000 && $3<65534 && $6 ~ /^\/home\// {print $1}'
    else
        echo "$INVOKING_USER"
    fi
}

# Run a command as a target user, keeping their environment/PATH intact.
as_user() {
    local u="$1"; shift
    if [ "$u" = "$(id -un)" ]; then
        "$@"
    elif [ "$(id -u)" -eq 0 ]; then
        sudo -u "$u" -H "$@"
    else
        return 1
    fi
}

# --- Output helpers -----------------------------------------------------------
if [ -t 1 ]; then B=$'\033[1m'; D=$'\033[2m'; R=$'\033[0m'; else B=""; D=""; R=""; fi

TOTAL=0
human() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}B"; }
credit() { TOTAL=$((TOTAL + ${1:-0})); }
say()  { printf '\n%s=== %s ===%s\n' "$B" "$*" "$R"; }
info() { printf '  %s\n' "$*"; }
skip() { printf '  %sskipped: %s%s\n' "$D" "$*" "$R"; }
run()  { if [ "$APPLY" -eq 1 ]; then "$@" >/dev/null 2>&1; else info "would run: $*"; fi; }

dir_bytes() { du -sb "$1" 2>/dev/null | cut -f1 || echo 0; }

need_root() {
    [ "$HAVE_ROOT" = "1" ] && return 0
    skip "needs root - re-run with sudo"
    return 1
}

AVAIL_BEFORE=$(df -B1 --output=avail / 2>/dev/null | tail -1)

# --- apt ----------------------------------------------------------------------
# Package archives are re-downloadable; autoremove drops orphaned deps and
# superseded kernels. Both are standard Ubuntu maintenance.
if wants apt; then
    say "APT cache and orphaned packages"
    if ! command -v apt-get >/dev/null; then
        skip "not a Debian/Ubuntu system"
    elif need_root; then
        bytes=$(dir_bytes /var/cache/apt)
        info "/var/cache/apt -> $(human "$bytes")"
        run $SUDO apt-get clean
        credit "$bytes"

        if [ "$APT_AUTOREMOVE" = "1" ]; then
            n=$($SUDO apt-get autoremove --dry-run 2>/dev/null |
                grep -c '^Remv ' || true)
            if [ "${n:-0}" -gt 0 ]; then
                info "$n orphaned package(s) can be autoremoved"
                [ "$APPLY" -eq 1 ] || info "would run: apt-get -y autoremove --purge"
                [ "$APPLY" -eq 1 ] && $SUDO apt-get -y autoremove --purge >/dev/null 2>&1
            else
                info "no orphaned packages"
            fi
        fi
    fi
fi

# --- snap ---------------------------------------------------------------------
# Snapd keeps old revisions of every snap mounted as loop devices. Disabled
# revisions are superseded and never used again - each is often 100-600M.
if wants snap; then
    say "Old snap revisions"
    if ! command -v snap >/dev/null; then
        skip "snapd not installed"
    elif need_root; then
        bytes=0; n=0
        while read -r name rev; do
            [ -n "$name" ] || continue
            f="/var/lib/snapd/snaps/${name}_${rev}.snap"
            [ -f "$f" ] && bytes=$((bytes + $(stat -c%s "$f" 2>/dev/null || echo 0)))
            n=$((n + 1))
            if [ "$APPLY" -eq 1 ]; then
                $SUDO snap remove "$name" --revision="$rev" >/dev/null 2>&1 \
                    && info "removed $name rev $rev" \
                    || info "could not remove $name rev $rev"
            else
                info "would remove $name rev $rev"
            fi
        done < <(snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}')

        if [ "$n" -eq 0 ]; then
            info "no disabled revisions"
        else
            info "$n revision(s), $(human "$bytes")"
            credit "$bytes"
        fi

        # Cap future accumulation (snapd default retains 3).
        if [ -n "$SNAP_RETAIN" ]; then
            run $SUDO snap set system refresh.retain="$SNAP_RETAIN"
        fi
    fi
fi

# --- journal ------------------------------------------------------------------
if wants journal; then
    say "systemd journal (retain $JOURNAL_KEEP)"
    if ! command -v journalctl >/dev/null; then
        skip "systemd not present"
    elif need_root; then
        info "$(journalctl --disk-usage 2>/dev/null || echo 'usage unknown')"
        run $SUDO journalctl --vacuum-size="$JOURNAL_KEEP"
    fi
fi

# --- logs ---------------------------------------------------------------------
# The generic failure this targets: a rotated log gets renamed to a suffix
# logrotate's glob does not match (foo.log.1-20260614.backup), so its
# `rotate N` policy never prunes it and the file lives forever. Only inert
# suffixes are candidates - never a live *.log/*.json, and never logrotate's
# own .gz/.N rotations, which are still inside a working retention policy.
if wants logs; then
    say "Orphaned rotated logs in /var/log (older than ${LOG_ORPHAN_AGE_DAYS}d)"
    if ! need_root; then
        :
    elif [ ! -d /var/log ]; then
        skip "/var/log not present"
    else
        mapfile -t orphans < <($SUDO find /var/log -type f \
            \( -name '*.backup' -o -name '*.old' -o -name '*.orig' \
               -o -name '*.save' -o -name '*.bak' \) \
            -mtime "+${LOG_ORPHAN_AGE_DAYS}" -print 2>/dev/null)

        if [ ${#orphans[@]} -eq 0 ]; then
            info "none found"
        else
            bytes=$($SUDO find /var/log -type f \
                \( -name '*.backup' -o -name '*.old' -o -name '*.orig' \
                   -o -name '*.save' -o -name '*.bak' \) \
                -mtime "+${LOG_ORPHAN_AGE_DAYS}" -printf '%s\n' 2>/dev/null |
                awk '{s+=$1} END {print s+0}')
            info "${#orphans[@]} file(s), $(human "$bytes")"

            # Show which services are responsible, not just a file count.
            printf '%s\n' "${orphans[@]}" | xargs -rn1 dirname | sort | uniq -c |
                sort -rn | head -5 | while read -r c d; do info "  ${c}x $d"; done

            # Never unlink a file a live process still holds open.
            held=""
            if command -v lsof >/dev/null; then
                held=$($SUDO lsof -- "${orphans[@]}" 2>/dev/null | tail -n +2)
            fi
            if [ -n "$held" ]; then
                skip "$(printf '%s\n' "$held" | wc -l) file(s) open by a live process"
            elif [ "$APPLY" -eq 1 ]; then
                printf '%s\0' "${orphans[@]}" | $SUDO xargs -0 rm -f --
                info "deleted"
                credit "$bytes"
            else
                info "would delete ${#orphans[@]} file(s)"
                credit "$bytes"
            fi
        fi
    fi
fi

# --- docker -------------------------------------------------------------------
# Build cache and dangling images only. Deliberately NOT --volumes (volumes
# are live data, e.g. database state) and NOT -a (that drops images with no
# running container that you would have to pull again).
if wants docker; then
    say "Docker build cache and dangling images"
    if ! command -v docker >/dev/null; then
        skip "docker not installed"
    elif ! docker info >/dev/null 2>&1; then
        skip "docker daemon not reachable by $(id -un)"
    else
        docker system df 2>/dev/null | sed 's/^/  /'
        run docker builder prune -f
        run docker image prune -f
        info "volumes and tagged images left untouched"
    fi
fi

# --- gocache ------------------------------------------------------------------
if wants gocache; then
    say "Go build cache"
    found=0
    for u in $(target_users); do
        as_user "$u" command -v go >/dev/null 2>&1 || continue
        c=$(as_user "$u" go env GOCACHE 2>/dev/null)
        [ -n "$c" ] && [ -d "$c" ] || continue
        found=1
        bytes=$(dir_bytes "$c")
        info "$u: $c -> $(human "$bytes")"
        if [ "$APPLY" -eq 1 ]; then
            as_user "$u" go clean -cache >/dev/null 2>&1
        else
            info "would run: go clean -cache (as $u)"
        fi
        credit "$bytes"
    done
    [ "$found" -eq 1 ] || skip "go not installed for any target user"
fi

# --- caches -------------------------------------------------------------------
# Regenerable app/tool caches under each user's XDG cache dir. Contents are
# cleared but the directory is kept, so tools do not trip on a missing path.
if wants caches; then
    say "User application caches"
    for u in $(target_users); do
        h=$(home_of "$u"); [ -n "$h" ] && [ -d "$h" ] || continue
        cachedir="$h/.cache"
        [ -d "$cachedir" ] || continue
        for name in "${CACHE_NAMES[@]}"; do
            c="$cachedir/$name"
            [ -d "$c" ] || continue
            bytes=$(dir_bytes "$c")
            [ "${bytes:-0}" -gt 10485760 ] || continue   # ignore anything under 10M
            info "$u: ~/.cache/$name -> $(human "$bytes")"
            if [ "$APPLY" -eq 1 ]; then
                find "$c" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null
            fi
            credit "$bytes"
        done
        # npm keeps its cache outside XDG and has a purpose-built purge command.
        if as_user "$u" command -v npm >/dev/null 2>&1 && [ -d "$h/.npm" ]; then
            bytes=$(dir_bytes "$h/.npm")
            if [ "${bytes:-0}" -gt 10485760 ]; then
                info "$u: ~/.npm -> $(human "$bytes")"
                [ "$APPLY" -eq 1 ] && as_user "$u" npm cache clean --force >/dev/null 2>&1
                credit "$bytes"
            fi
        fi
    done
    [ "$APPLY" -eq 1 ] || info "would clear the above"
fi

# --- trash --------------------------------------------------------------------
if wants trash; then
    say "Desktop trash"
    for u in $(target_users); do
        h=$(home_of "$u"); [ -n "$h" ] || continue
        t="$h/.local/share/Trash"
        [ -d "$t" ] || continue
        bytes=$(dir_bytes "$t")
        [ "${bytes:-0}" -gt 1048576 ] || continue
        info "$u: $t -> $(human "$bytes")"
        if [ "$APPLY" -eq 1 ]; then
            find "$t" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null
        fi
        credit "$bytes"
    done
    [ "$APPLY" -eq 1 ] || info "would empty the above"
fi

# --- makeclean ----------------------------------------------------------------
# For monorepos of Makefile-driven components: runs `make clean` in every
# immediate subdirectory that has one. Self-contained - depends on nothing
# but make itself, so it behaves the same on a fresh machine. Sources, .git
# and vendor/ are never touched; `make clean` only drops build output.
if wants makeclean; then
    say "Build artifacts in Makefile repos"

    # Auto-detect common Go monorepo layouts when nothing is configured.
    if [ -z "$MAKE_CLEAN_DIRS" ]; then
        for u in $(target_users); do
            gp=$(as_user "$u" go env GOPATH 2>/dev/null) || continue
            [ -n "$gp" ] && [ -d "$gp/src" ] || continue
            # A dir is a candidate only if its subdirs are Makefile components.
            while IFS= read -r d; do
                [ -n "$(find "$d" -mindepth 2 -maxdepth 2 -name Makefile -print -quit \
                        2>/dev/null)" ] || continue
                MAKE_CLEAN_DIRS="${MAKE_CLEAN_DIRS:+$MAKE_CLEAN_DIRS:}$d"
            done < <(find "$gp/src" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
        done
    fi

    if [ -z "$MAKE_CLEAN_DIRS" ]; then
        skip "no dirs configured (use --make-dir PATH or set MAKE_CLEAN_DIRS)"
    else
        IFS=: read -r -a mdirs <<< "$MAKE_CLEAN_DIRS"
        for d in "${mdirs[@]}"; do
            [ -d "$d" ] || { skip "$d not found"; continue; }

            bytes=$(find "$d" -maxdepth 2 -type d \( -name bin -o -name .go \) \
                    -exec du -sb {} + 2>/dev/null | awk '{s+=$1} END {print s+0}')
            info "$d -> $(human "$bytes") in bin/ and .go/"

            owner=$(stat -c%U "$d" 2>/dev/null)

            # Components are the immediate subdirs that have a Makefile. The
            # same list drives both the dry-run count and the apply loop, so
            # what is promised and what happens cannot disagree. A top-level
            # Makefile is the monorepo's own, not a component - hence mindepth 2.
            mapfile -t subs < <(find "$d" -mindepth 2 -maxdepth 2 \
                                -name Makefile -printf '%h\n' 2>/dev/null | sort)

            if [ ${#subs[@]} -eq 0 ]; then
                skip "no Makefile components under $d"
            elif [ "$APPLY" -eq 1 ]; then
                ok=0; bad=0
                for sub in "${subs[@]}"; do
                    # Only clean where a `clean` target actually exists, so a
                    # component without one is reported rather than counted.
                    if ! as_user "$owner" bash -c \
                         "cd '$sub' && make -n clean" >/dev/null 2>&1; then
                        bad=$((bad + 1))
                        info "  no clean target: $(basename "$sub")"
                        continue
                    fi
                    if as_user "$owner" bash -c "cd '$sub' && make clean" \
                         >/dev/null 2>&1; then
                        ok=$((ok + 1))
                    else
                        bad=$((bad + 1))
                        info "  clean failed: $(basename "$sub")"
                    fi
                done
                info "cleaned $ok component(s)$([ "$bad" -gt 0 ] && echo ", $bad skipped")"
            else
                info "would run 'make clean' in ${#subs[@]} component(s)"
            fi
            credit "$bytes"
        done
    fi
fi

# --- summary ------------------------------------------------------------------
say "Summary"
if [ "$APPLY" -eq 1 ]; then
    sync
    AVAIL_AFTER=$(df -B1 --output=avail / 2>/dev/null | tail -1)
    info "available before: $(human "$AVAIL_BEFORE")"
    info "available after:  $(human "$AVAIL_AFTER")"
    info "${B}freed: $(human $((AVAIL_AFTER - AVAIL_BEFORE)))${R}"
else
    info "would free roughly: ${B}$(human "$TOTAL")${R}"
    info "currently available: $(human "$AVAIL_BEFORE")"
    printf '\n  %sDRY RUN - nothing changed. Re-run with --apply.%s\n' "$B" "$R"
    [ "$HAVE_ROOT" = "1" ] || printf '  %sNot root: apt/snap/journal/logs were skipped. Use sudo for those.%s\n' "$D" "$R"
fi
