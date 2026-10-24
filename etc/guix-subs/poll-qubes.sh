#!/bin/sh
# poll-qubes.sh — run by mcron (config.scm) every 10 minutes, as root.
# When the qubes channel's branch head has moved since the last attempt,
# runs build-qubes.sh --qubes-only --no-wait: qubes-guix at its head, the
# other channels at the commits last published. The nightly run moves
# those.
#
#   poll-qubes.sh [BUILD-QUBES.SH]   (default /etc/guix-subs/build-qubes.sh)
set -u
export HOME=/root
export PATH=/run/current-system/profile/bin:/run/current-system/profile/sbin
build=${1:-/etc/guix-subs/build-qubes.sh}
state=/var/lib/guix-subs/qubes-head-tried   # the head last tried here
log() { echo "$(date -Is) poll: $*"; }

# The qubes channel's URL and branch, from what root pulls.
url=$(grep -A3 "(name 'qubes)" /etc/guix/channels.scm | sed -n 's/.*(url "\(.*\)").*/\1/p' | head -n1)
branch=$(grep -A4 "(name 'qubes)" /etc/guix/channels.scm | sed -n 's/.*(branch "\(.*\)").*/\1/p' | head -n1)
[ -n "$url" ] || { log "no qubes channel in /etc/guix/channels.scm"; exit 1; }
head=$(git ls-remote "$url" "refs/heads/${branch:-main}" | cut -f1)
[ -n "$head" ] || { log "couldn't read $url ${branch:-main}"; exit 1; }
[ "$head" = "$(cat "$state" 2>/dev/null)" ] && exit 0

log "qubes-guix ${branch:-main} is at $head; building it"
"$build" --qubes-only --no-wait
rc=$?
case $rc in
    75) log "another build is running; next poll";;
    *)  # Tried, good or not: a failing commit isn't retried every 10
        # minutes (the next commit, or the nightly run, moves on).
        mkdir -p "${state%/*}" && echo "$head" > "$state"
        log "build-qubes.sh --qubes-only for $head: exit $rc";;
esac
exit $rc
