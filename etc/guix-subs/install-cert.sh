#!/bin/sh
# install-cert.sh — read a PEM bundle on stdin (the private key, then the
# certificate chain), check it, install it for nginx's HTTPS server and
# reload nginx. Run as /etc/guix-subs-install-cert (config.scm), which puts
# openssl and herd on PATH; the Proxmox host's guix-subs-cert sends the
# bundle through the QEMU guest agent:
#   cat KEY CHAIN | qm guest exec VMID --pass-stdin 1 -- /etc/guix-subs-install-cert
set -eu

tls=/etc/guix-subs-tls
die() { echo "install-cert: $*" >&2; exit 1; }

umask 077
mkdir -p "$tls"
tmp=$(mktemp -d "$tls/.new.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/bundle.pem"
openssl pkey -in "$tmp/bundle.pem" -out "$tmp/privkey.pem" 2>/dev/null ||
    die "no private key in the bundle"
sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
    "$tmp/bundle.pem" > "$tmp/fullchain.pem"
openssl x509 -in "$tmp/fullchain.pem" -noout 2>/dev/null ||
    die "no certificate in the bundle"

# The key must be the certificate's: compare their public keys.
k=$(openssl pkey -in "$tmp/privkey.pem" -pubout)
c=$(openssl x509 -in "$tmp/fullchain.pem" -noout -pubkey)
[ "$k" = "$c" ] || die "the private key doesn't match the certificate"

chmod 600 "$tmp/privkey.pem"
chmod 644 "$tmp/fullchain.pem"
mv "$tmp/privkey.pem" "$tls/privkey.pem"
mv "$tmp/fullchain.pem" "$tls/fullchain.pem"
herd reload nginx >/dev/null 2>&1 || herd start nginx >/dev/null
echo "install-cert: installed: $(openssl x509 -in "$tls/fullchain.pem" -noout -subject -enddate | tr '\n' ' ')"
