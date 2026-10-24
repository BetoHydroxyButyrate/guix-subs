#!/bin/sh
# build-qubes.sh — run nightly by mcron (config.scm), as root. Pulls the
# channels in /etc/guix/channels.scm (guix, qubes, beto), then builds:
#   - template.scm: a typical qubes-guix template system;
#   - each package named in /etc/guix-subs/packages (if present).
# Each result is kept by a symlink under /var/guix/gcroots/qubes-builds (any
# symlink there is a GC root), replaced only once the new build succeeded:
# 'guix gc' keeps the latest good builds and 'guix publish' serves them.
# Once the template system (and the packages) have built, the Guix commit
# they were built from are published in /var/lib/qubes-builds: every
# channel's in channel-commits (nginx: /channel-commits), Guix's alone in
# guix-commit (/guix-commit), for qubes-guix-update --guix-commit server
# and qubes-guix-create.
#
#   build-qubes.sh [--qubes-only] [--no-wait]
#
# --qubes-only: the qubes channel at its head, every other channel at the
# commits last published (channel-commits), so only what depends on qubes-
# guix is built; run by poll-qubes.sh on each new qubes-guix commit. The
# published commits then stay a set this server has built, for qubes that
# lock to them. Without published commits yet, a full run.
# --no-wait: if another build is running, exit 75 rather than wait for it.
set -u
qubes_only=0 wait=1
for a in "$@"; do
    case $a in
        --qubes-only) qubes_only=1;;
        --no-wait) wait=0;;
        *) echo "build-qubes.sh: unknown argument $a" >&2; exit 2;;
    esac
done
export HOME=/root
export PATH=/run/current-system/profile/bin:/run/current-system/profile/sbin
# mcron's environment has no CA certificates for git (Guix's git doesn't
# look in /etc/ssl/certs by itself; guix pull does).
export SSL_CERT_DIR=/etc/ssl/certs
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export GIT_SSL_CAINFO=$SSL_CERT_FILE
dir=/etc/guix-subs
roots=/var/guix/gcroots/qubes-builds
mkdir -p "$roots"
template_ok=0
log() { echo "$(date -Is) $*"; }

# One build at a time (the nightly run, poll-qubes.sh, a CI run's sync).
mkdir -p /var/lib/guix-subs
exec 9>/var/lib/guix-subs/build.lock
if [ "$wait" = 1 ]; then
    flock 9
elif ! flock -n 9; then
    log "another build is running"; exit 75
fi

# keep NAME OUTPUT...: point NAME (NAME-1, NAME-2... for more outputs) at
# the new outputs, dropping the previous build's links.
keep() {
    name=$1; shift
    rm -f "$roots/$name" "$roots/$name"-[0-9]*
    i=0
    for out in "$@"; do
        if [ "$i" = 0 ]; then link=$roots/$name; else link=$roots/$name-$i; fi
        ln -sfn "$out" "$link"
        i=$((i + 1))
    done
}

# Pull with root's pulled guix once there is one (it knows the qubes and
# beto channels, so no "not trusted" warnings), else the system's.
guix=/root/.config/guix/current/bin/guix
[ -x "$guix" ] || guix=guix
published=/var/lib/qubes-builds/channel-commits
if [ "$qubes_only" = 1 ] && [ -s "$published" ]; then
    # /etc/guix/channels.scm (one expression, a list of channels), every
    # channel but qubes pinned to its published commit.
    pins=$(awk '$1 != "qubes" && $2 ~ /^[0-9a-f]+$/ {printf "(%s . \"%s\") ", $1, $2}' "$published")
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    {
        echo ";; Written by build-qubes.sh --qubes-only."
        echo "(let ((pins '($pins)))"
        echo "  (map (lambda (c)"
        echo "         (let ((pin (assq-ref pins (channel-name c))))"
        echo "           (if pin (channel (inherit c) (commit pin)) c)))"
        sed 's/^/       /' /etc/guix/channels.scm
        echo "))"
    } > "$tmp/channels.scm"
    log "pull: qubes at its head, the others at the published commits"
    # --allow-downgrades: root's Guix may be newer than the published
    # commits, if a nightly build failed after its pull.
    "$guix" pull --allow-downgrades -C "$tmp/channels.scm" || { log "pull failed"; exit 1; }
else
    [ "$qubes_only" = 1 ] && log "no published commits yet: a full run"
    log "pull"
    "$guix" pull || { log "pull failed"; exit 1; }
fi
guix=/root/.config/guix/current/bin/guix
"$guix" describe

log "template system"
if out=$("$guix" system build "$dir/template.scm" | tail -n 1) &&
   [ -d "$out" ]; then
    keep template "$out"
    log "template: $out"
    template_ok=1
else
    log "template build FAILED (previous build kept)"
fi

if [ -f "$dir/packages" ]; then
    # One at a time: a name this Guix lacks only skips that package.
    grep -v '^[[:space:]]*\(#\|$\)' "$dir/packages" | tr -s ' \t' '\n\n' |
    while read -r p; do
        [ -n "$p" ] || continue
        log "package $p"
        if outs=$("$guix" build "$p") && [ -n "$outs" ]; then
            # shellcheck disable=SC2086 # one store path per line
            keep "pkg-$p" $outs
        else
            log "package $p FAILED or unknown (previous build kept)"
        fi
    done
fi
# Publish the commits last, once the packages are built too: a qube that
# locks to them then finds everything here. Not if the template failed.
#   channel-commits  every channel, one "NAME COMMIT" per line, in
#                    'guix describe' order (guix first)
#   guix-commit      just Guix's, for qubes-guix versions that only read it
# Commits only, no URLs or introductions: a qube applies them to its own
# channel definitions, so it still authenticates each channel itself.
publish() {   # publish FILE: stdin -> /var/lib/qubes-builds/FILE, atomically
    cat > "/var/lib/qubes-builds/$1.new" &&
    chmod 644 "/var/lib/qubes-builds/$1.new" &&
    mv "/var/lib/qubes-builds/$1.new" "/var/lib/qubes-builds/$1"
}
if [ "$template_ok" = 1 ]; then
    mkdir -p /var/lib/qubes-builds
    commits=$("$guix" describe |
              awk '/^  [^ ]/ {name = $1}
                   /^    commit: / && name != "" {print name, $2; name = ""}')
    commit=$(printf '%s\n' "$commits" | awk '$1 == "guix" {print $2}')
    if [ -n "$commit" ]; then
        printf '%s\n' "$commits" | publish channel-commits
        printf '%s\n' "$commit" | publish guix-commit
        log "published channel commits:"
        printf '%s\n' "$commits" | sed 's/^/    /'
    else
        log "no guix commit in 'guix describe': nothing published"
    fi
fi
log "done"
