#!/bin/sh
# build-qubes.sh — run nightly by mcron (config.scm), as root. Pulls the
# channels in /etc/guix/channels.scm (guix, qubes, beto), then builds:
#   - template.scm: a typical qubes-guix template system;
#   - each package named in /etc/guix-subs/packages (if present).
# Each result is kept by a symlink under /var/guix/gcroots/qubes-builds (any
# symlink there is a GC root), replaced only once the new build succeeded:
# 'guix gc' keeps the latest good builds and 'guix publish' serves them.
# Once the template system (and the packages) have built, the Guix commit
# they were built from is published as /var/lib/qubes-builds/guix-commit (nginx: /guix-commit), for
# qubes-guix-update --guix-commit server and qubes-guix-create.
set -u
export HOME=/root
export PATH=/run/current-system/profile/bin:/run/current-system/profile/sbin
dir=/etc/guix-subs
roots=/var/guix/gcroots/qubes-builds
mkdir -p "$roots"
template_ok=0
log() { echo "$(date -Is) $*"; }

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
log "pull"
"$guix" pull || { log "pull failed"; exit 1; }
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
# Publish the Guix commit last, once the packages are built too: a qube
# that locks to it then finds everything here. Not if the template failed.
if [ "$template_ok" = 1 ]; then
    commit=$("$guix" describe |
             awk '/^  guix /{g=1; next} /^  [^ ]/{g=0} g && /commit:/{print $2; exit}')
    if [ -n "$commit" ]; then
        mkdir -p /var/lib/qubes-builds
        printf '%s\n' "$commit" > /var/lib/qubes-builds/guix-commit.new
        chmod 644 /var/lib/qubes-builds/guix-commit.new
        mv /var/lib/qubes-builds/guix-commit.new /var/lib/qubes-builds/guix-commit
        log "published guix commit $commit"
    fi
fi
log "done"
