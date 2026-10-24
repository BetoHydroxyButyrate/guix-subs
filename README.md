# guix-subs

A Guix System VM on Proxmox that serves substitutes to the Guix qubes made with
[qubes-guix](https://github.com/BetoHydroxyButyrate/qubes-guix). Templates and
AppVMs fetch from your LAN instead of building or downloading everything
themselves.

It does four things:

- **Builds what the qubes need, every night.** A typical qubes-guix template
  system (Qubes agents included), plus a list of packages. IceCat, for example,
  runs a template out of memory if it has to build it itself.
- **Serves its store** with `guix publish`. Everything it built or fetched is
  signed with its own key.
- **Caches bordeaux and ci.** nginx proxies `bordeaux.guix.gnu.org` and
  `ci.guix.gnu.org` and keeps what it has fetched, so the second qube to need
  a package gets it from the LAN. These keep the upstream signatures, so they
  need no extra key.
- **Publishes the channel commits of its last good build** at
  `/channel-commits`: one `NAME COMMIT` line per channel (guix, qubes, beto,
  nonguix). Substitutes only match when the qube uses the *same* commits, so
  qubes lock to them: `qubes-guix-update --guix-commit server`. `/guix-commit`
  still has Guix's alone, for qubes-guix versions that only read that.

```
http://guix-subs.example.lan/              this machine's store (guix publish, :8080)
http://guix-subs.example.lan/bordeaux/     bordeaux.guix.gnu.org, cached
http://guix-subs.example.lan/ci/           ci.guix.gnu.org, cached
http://guix-subs.example.lan/channel-commits  channel commits of the last good nightly build
http://guix-subs.example.lan/guix-commit      Guix's commit alone
```

## Files

```
etc/guix-subs/          copied to /etc/guix-subs on the VM
  config.scm            the operating system
  build-qubes.sh        nightly job (mcron, 02:00): pull, build, publish the commit
  poll-qubes.sh         every 10 min (mcron): build a new qubes-guix commit at once
  template.scm          the template system it builds: Xfce + qubes-guix
  packages              extra packages to build or fetch nightly
  install-cert.sh       installs the TLS certificate the Proxmox host pushes in
  beto-ssh.pub          your SSH public key (not in git; see .example)
mk-subs.sh              on Proxmox: creates and starts the VM
install.sh              installs the VM from the Guix installer's shell
pve/                    on the Proxmox host: the TLS certificate (section 6)
```

The examples below call the machine `guix-subs.example.lan`. In
`config.scm`, set `%host-name` to the name your qubes will use (nginx's
`server_name`, and the certificate's), and
change the user (`beto`), the timezone and the locale to suit.

## 1. The Proxmox VM

Proxmox can be any host. The VM wants disk and cores rather than anything
special:

| | |
|---|---|
| Machine | q35, **SeaBIOS** (config.scm uses GRUB for BIOS) |
| CPU | type `host`, 16 cores |
| Memory | 32 GB, ballooning off |
| Disk | **VirtIO SCSI single** controller (so it's `/dev/sda`), ~400 GB on NVMe, discard + SSD emulation + iothread |
| Network | VirtIO, on the VLAN your Qubes UpdateVM reaches |
| Serial | `serial0 socket`, for `qm terminal` and the xterm.js console |
| Agent | QEMU guest agent enabled |

On the Proxmox host, with the Guix installer ISO uploaded to an ISO storage
(get it from guix.gnu.org and check its signature):

```sh
./mk-subs.sh 120                                   # VMID 120, named guix-subs
./mk-subs.sh 120 guix-subs local-lvm local:iso '' 30   # other storages, VLAN 30
```

`mk-subs.sh VMID [HOST] [DISK-STORAGE] [ISO-STORAGE] [ISO-NAME] [VLAN]`
runs the `qm create` with the settings above, starts the VM, and prints the
next steps. The defaults are `guix-subs`, `local-zfs`, `proxmox:iso`, the
1.5.0 installer ISO and no VLAN; an empty argument takes the default. Edit
the script for a different bridge, size or core count.

The VM boots the ISO while it's attached, so a reset during the install lands
back in the installer. Once Guix is installed, detach the ISO (section 2) and
it boots from the disk.

## 2. Install Guix

`install.sh` installs the final system from the installer's shell: no
graphical installer and no reconfigure. **It wipes the disk** (`/dev/sda`).

1. On the Proxmox host (or any machine the VM can reach), serve a checkout of
   this repository, with your SSH public key added:
   ```sh
   git clone https://github.com/BetoHydroxyButyrate/guix-subs  # or scp it over
   cp ~/.ssh/id_ed25519.pub guix-subs/etc/guix-subs/beto-ssh.pub   # your key
   cd guix-subs && python3 -m http.server 8000
   ```
   Proxmox has `python3`. If its firewall is on, open port 8000 for now.
2. In the VM's noVNC console, choose the non-graphical install and open a
   shell. The network comes up by itself. Then, with the Proxmox host at
   192.168.3.11 for example:
   ```sh
   wget http://192.168.3.11:8000/install.sh
   sh install.sh http://192.168.3.11:8000
   ```
   It fetches the files, partitions `/dev/sda` (a BIOS boot partition and an
   ext4 root labelled `guix-root`), copies the files to `/etc/guix-subs`
   and runs `guix system init`. A different disk is the second argument;
   a disk that already has partitions needs `FORCE=1 sh install.sh …`.
3. Stop the HTTP server, detach the ISO
   (`qm set $VMID --ide2 none,media=cdrom`), and `reboot`.
4. Root's password is empty, which is fine only until you log in once on
   the console (`qm terminal $VMID`) and run `passwd`.

The system is built by the installer's Guix, so the serial console and the
guest agent work from the first boot. The nightly job does root's first
`guix pull`.

**By hand instead:** run the graphical installer (minimal system, user `beto`,
ext4), label the root `guix-root` (`sudo e2label "$(findmnt -no SOURCE /)"
guix-root`), put this directory and your key in `/etc/guix-subs`, then
`sudo -H guix pull && sudo guix system reconfigure /etc/guix-subs/config.scm`
and reboot. The first pull warns that the qubes, beto and nonguix channels
are "not trusted"; that's harmless.

After the reboot there's no desktop or password login. Use:

- `ssh beto@guix-subs`
- `qm terminal $VMID` on the Proxmox host (Ctrl+O to leave), or the xterm.js
  console, for when the network is down
- `qm guest exec $VMID -- herd status nginx`, for one-off commands

## 3. First build

```sh
sudo sh -c 'nohup /etc/guix-subs/build-qubes.sh >> /var/log/qubes-builds.log 2>&1 &'
tail -f /var/log/qubes-builds.log
```

The first run pulls Guix and all the channels, builds the Qubes agents and the
template system, then everything in `packages`. Most of it comes as
substitutes, and firefox-esr comes from nonguix's farm. Later runs are at
02:00 nightly. A weekly job at 04:00 Sunday deletes root's Guix generations
older than a month and runs `guix gc -F 150G`: it collects garbage until at
least 150 GiB of the disk are free.

**Each new qubes-guix commit** is built within about 10 minutes, without
waiting for the night. `poll-qubes.sh` (mcron, every 10 minutes) compares the
qubes channel's branch head with the last one it tried. When it has moved, it
runs `build-qubes.sh --qubes-only --no-wait`:

- **The pull:** qubes-guix at its head, and every other channel (Guix,
  beto, nonguix) pinned to the commits last published. Only what depends
  on qubes-guix is built: the Qubes packages, the pulled Guix with the
  qubes channel, and the template system.
- **The publish:** as usual, `channel-commits` is published at the end,
  with the new qubes commit and the other channels unchanged. So it's
  always a set this server has built, and `qubes-guix-update --guix-commit
  server -r` in a template gets substitutes for all of it. The nightly
  run moves the other channels forward.
- **One build at a time:** `build-qubes.sh` holds
  `/var/lib/guix-subs/build.lock`. The nightly run and a CI run's sync
  (`sudo build-qubes.sh`) wait for a build in progress; the poll skips and
  tries again next time (`--no-wait`, exit 75).
- **A failing commit isn't retried every 10 minutes.** The poll records
  each head it tried, good or not, in `/var/lib/guix-subs/qubes-head-tried`.
  The next commit, or the nightly run, moves on.

To build the current qubes-guix head now, by hand:
`sudo /etc/guix-subs/build-qubes.sh --qubes-only`. Run from a terminal,
`build-qubes.sh` also appends its output to `/var/log/qubes-builds.log`,
so no `tee` is needed.

Each result is kept by a symlink in `/var/guix/gcroots/qubes-builds/`. Any
symlink there is a GC root, and it's replaced only once the new build
succeeds. When the template and packages are done, the run writes the
channel commits to `/var/lib/qubes-builds/channel-commits`, and Guix's to
`guix-commit` next to it. A night whose template build fails publishes
nothing, so the last good commits stay.

They're commits only, no URLs or channel introductions. A qube applies them
to its own channel definitions, so it still authenticates every channel
itself: guix-subs can choose which commit a qube builds, but can't point it
at another repository.

Get the signing key the qubes need:

```sh
cat /etc/guix/signing-key.pub      # public: fine to copy around
```

Never copy `signing-key.sec` anywhere. Every qube that trusts the public key
accepts any binary this machine signs, so guix-subs is part of every such
qube's trusted base: keep it patched, reachable only from your LAN, and with
SSH by key only.

## 4. Checks

```sh
curl -s http://guix-subs.example.lan/nix-cache-info             # guix publish
curl -sI http://guix-subs.example.lan/bordeaux/nix-cache-info | grep -i x-cache   # MISS, then HIT
curl -s http://guix-subs.example.lan/channel-commits             # after a good run
sudo herd status nginx guix-publish dns-ready
ls -l /var/guix/gcroots/qubes-builds/
```

From a Guix qube:

```sh
guix weather --substitute-urls=http://guix-subs.example.lan qubes-core-qrexec icecat
```

## 5. The qubes

With qubes-guix, put the servers in dom0's `qubes-guix-substitutes`, next to
`qubes-guix-create`:

```
url http://guix-subs.example.lan
url http://guix-subs.example.lan/bordeaux
url http://guix-subs.example.lan/ci
key (public-key (ecc (curve Ed25519) (q #…#)))     # /etc/guix/signing-key.pub, one line
```

- **A new template** gets them at install, and builds at the server's commit:
  ```sh
  qubes-guix-create --unattended --template -n <netvm that reaches guix-subs> \
    --guix-commit server NAME
  ```
- **An existing qube:** add `#:extra-substitute-urls '("http://…" …)` and
  `#:extra-authorized-keys (list "(public-key …)")` to its `/etc/config.scm`.
  Then `qubes-guix-update --guix-commit server`. It locks to the server's
  commit, pulls and reconfigures.
- **Moving to a newer build later** is that same command:
  `qubes-guix-update --guix-commit server`.
- **What gets locked:** every channel the qube shares with guix-subs (guix,
  qubes, nonguix, beto), from `/channel-commits`, recorded as
  `#:channel-commits` in its config.scm. Then the Qubes agents and firefox-esr
  come from here too, not just what's in Guix proper. A qubes-guix older
  than this reads only `/guix-commit` and locks Guix alone.
- **Working on qubes-guix itself:** add `#:follow-head '(qubes)` to the qube's
  `qubes-operating-system` form and run `qubes-guix-update -r`. The qubes
  channel follows its branch; the other channels stay locked. Remove it to
  go back to the server's qubes commit.
- **If the qube is ahead of the server** (it pulled a newer Guix itself, or
  the server's last few nights failed), moving to the server's commit is a
  downgrade, and `guix pull` refuses it. Add `--allow-downgrades`, or wait
  for the server's next good build.

qubes-guix lists these servers *before* bordeaux and ci, which stay as the
fallback, so guix-subs being down only makes things slower.

A **template** updates through the Qubes updates proxy, tinyproxy in the
UpdateVM. So the UpdateVM must reach guix-subs: the `qubes.UpdatesProxy` target
in dom0's policy, with the `updates-proxy` service on. Here that's a firewall
qube on guix-subs' VLAN. AppVMs reach it through their netvm.

## 6. HTTPS

nginx serves the same things on 443 as on 80. The certificate comes from the
Proxmox host, which already has your Route 53 credentials for its own ACME
(Datacenter > ACME, a DNS plugin with API "aws"). `pve/guix-subs-cert` reads
them from there, gets a certificate for guix-subs with
[lego](https://go-acme.github.io/lego/) (DNS-01, so nothing needs to reach
the VM from outside), and pipes the key and chain into the VM through the
QEMU guest agent, where `/etc/guix-subs-install-cert` checks them, installs
them in `/etc/guix-subs-tls` and reloads nginx. So:

- guix-subs never holds the Route 53 credentials, which can change your
  whole zone;
- the certificate has its own key, not the Proxmox node's (that one guards
  the Proxmox web UI);
- until the first push, nginx uses a self-signed placeholder, and port 80
  works as before. Nothing redirects to HTTPS.

On the Proxmox host, as root:

```sh
apt install lego
install -m 755 pve/guix-subs-cert /usr/local/sbin/
install -m 600 pve/guix-subs-cert.default /etc/default/guix-subs-cert
install -m 644 pve/guix-subs-cert.service pve/guix-subs-cert.timer /etc/systemd/system/
$EDITOR /etc/default/guix-subs-cert         # VMID, DOMAIN, ACME_EMAIL, PLUGIN
systemctl daemon-reload
systemctl start guix-subs-cert              # the first certificate, now
journalctl -u guix-subs-cert                # "pushed the certificate ..."
systemctl enable --now guix-subs-cert.timer # then daily; renews 30 days ahead
```

It pushes only when the certificate changed, and retries a push that failed
(the VM down, say) at the next run. `FORCE=1 guix-subs-cert` pushes anyway,
e.g. after reinstalling the VM.

Check it from a qube:

```sh
curl -s https://guix-subs.example.com/nix-cache-info
```

The name has to be the certificate's: a real name in your Route 53 zone,
which your LAN's DNS resolves to the VM. A `.lan` name like the examples
above can't get a public certificate.

Then switch the qubes' `url` lines (dom0's `qubes-guix-substitutes`, and
`#:extra-substitute-urls` in existing qubes' config.scm) to `https://`.
tinyproxy then only tunnels, and `/channel-commits` is protected in transit.

The IAM user behind the plugin needs only `route53:ChangeResourceRecordSets`
and `route53:ListResourceRecordSets` on your zone, plus `route53:GetChange`
and `route53:ListHostedZonesByName`.

## What we learned

- **Same commits or no hit.** A substitute matches only an identical
  derivation, so the same commit of every channel it depends on. guix-subs
  following the latest Guix while templates follow it separately rarely
  matches. And locking Guix alone wasn't enough either: the qubes channel
  still followed its branch, so the Qubes agents were built in the template.
  Hence `/channel-commits` and `--guix-commit server` locking every channel.
- **Extra servers go first.** Guix takes each item from the first server in the
  list that has it. An extra server appended after bordeaux and ci was hardly
  used, so qubes-guix now puts it first.
- **nginx starts too early at boot.** It resolves the `proxy_pass` host names
  once, at start-up. Before DHCP had provided DNS, its config check failed,
  `nginx-init` failed, and nginx stayed down, with nothing in its error log
  (Shepherd's log, `/var/log/messages`, had it). The `dns-ready` service makes
  it wait until every upstream host resolves. Waiting for bordeaux alone
  wasn't enough: IPv6 (with its DNS server) came up six seconds before the
  IPv4 lease, and nginx resolves with `AI_ADDRCONFIG`, so ci, which has no
  IPv6 address, didn't resolve yet while bordeaux did. `dns-ready` now asks
  the same way. Shepherd doesn't retry a failed start: `sudo herd start
  nginx` if it happens.
- **`guix build --root` won't replace a link.** The second night failed with
  "File exists". Roots are now plain symlinks in `/var/guix/gcroots/…`, swapped
  after a good build.
- **"500 Unable to connect"** in a template's update is tinyproxy (the updates
  proxy) failing to reach guix-subs: nginx down, or the UpdateVM can't route
  there. Guix falls back to the next server.
- **Plain HTTP through the updates proxy.** tinyproxy handles each plain-HTTP
  request itself; HTTPS it just tunnels. One update died early on with
  `Bad Read-Header-Line header: #<eof>`, which fits tinyproxy mishandling
  Guix's pipelined narinfo requests, though nginx being down may also have
  played a part. It hasn't recurred since nginx was fixed. If it does, serve
  guix-subs over HTTPS (section 6).
- **Big packages belong here, not in templates.** IceCat (and Firefox) need far
  more memory than a template has. The kernel killed `cargo` in a template.
  List them in `packages` and lock the template to the server's commit.
- **One getty on the serial console.** `%base-services` already runs an
  agetty on the kernel's `console=` device. A second one on `ttyS0` made the
  two fight: logins worked but bash had no job control ("cannot set terminal
  process group").
- **Guix 1.5 details:** `dhcp-client-service-type` is gone, so use
  `dhcpcd-service-type`. With the graphical installer, the serial getty and
  the QEMU guest agent only work after the first reconfigure (install.sh
  avoids this). Before then, use noVNC.
- **`guix describe` shows the pulled Guix, not the system config.** After
  adding a channel to config.scm and reconfiguring, `sudo -H guix pull` before
  it shows up.
- **nonguix:** this config fetches from `substitutes.nonguix.org`, so
  firefox-esr isn't built here. Don't pin nonguix to a commit while Guix
  follows the latest: nonguix tracks current Guix, and an old nonguix can stop
  building against a newer Guix.

## To do

- **Building every commit of every channel:** Cuirass, if per-commit
  qubes-guix plus nightly for the rest turns out too coarse.
- **More build power:** `guix offload` to a Guix VM on the TrueNAS box (40
  cores), if one build machine isn't enough.
