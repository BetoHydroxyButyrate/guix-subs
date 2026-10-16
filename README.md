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
- **Publishes the Guix commit of its last good build** at `/guix-commit`.
  Substitutes only match when the qube uses the *same* Guix commit, so qubes
  lock to that commit: `qubes-guix-update --guix-commit server`.

```
http://guix-subs.example.lan/              this machine's store (guix publish, :8080)
http://guix-subs.example.lan/bordeaux/     bordeaux.guix.gnu.org, cached
http://guix-subs.example.lan/ci/           ci.guix.gnu.org, cached
http://guix-subs.example.lan/guix-commit   Guix commit of the last good nightly build
```

## Files

```
etc/guix-subs/          copied to /etc/guix-subs on the VM
  config.scm            the operating system
  build-qubes.sh        nightly job (mcron, 02:00): pull, build, publish the commit
  template.scm          the template system it builds: Xfce + qubes-guix
  packages              extra packages to build or fetch nightly
  beto-ssh.pub          your SSH public key (not in git; see .example)
mk-subs.sh              on Proxmox: creates and starts the VM
install.sh              installs the VM from the Guix installer's shell
```

The examples below call the machine `guix-subs.example.lan`. In
`config.scm`, set nginx's `server_name` to the name your qubes will use, and
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

Each result is kept by a symlink in `/var/guix/gcroots/qubes-builds/`. Any
symlink there is a GC root, and it's replaced only once the new build
succeeds. When the template and packages are done, the run writes the Guix
commit to `/var/lib/qubes-builds/guix-commit`. A night whose template build
fails publishes nothing, so the last good commit stays.

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
curl -s http://guix-subs.example.lan/guix-commit                 # after a good run
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

## What we learned

- **Same commit or no hit.** A substitute matches only an identical derivation,
  so the same Guix commit (and the same commits of the other channels).
  guix-subs following the latest Guix while templates follow it separately
  rarely matches. Hence `/guix-commit` and `--guix-commit server`.
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
  guix-subs over HTTPS (see below).
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

- **Publish every channel's commit, not just Guix's.** A qube's firefox-esr only
  matches if its nonguix commit equals guix-subs' too, and the same goes for
  qubes and beto packages. `/guix-commit` should become the whole
  `guix describe -f channels`, and `--guix-commit server` should lock every
  channel.
- **HTTPS.** A Let's Encrypt certificate for the name, issued with a DNS
  challenge so the VM needs no inbound access, and nginx on 443. Then tinyproxy
  only tunnels, as it does for bordeaux. It also protects `/guix-commit`:
  substitutes are signed and nars are hash-checked, so plain HTTP is safe
  for them, but nothing signs the commit. Channel authentication still
  rejects a forged commit, yet someone on the path could hold the qubes at
  an old, genuine one.
- **Building every commit, not nightly:** Cuirass, if nightly turns out too
  coarse.
- **More build power:** `guix offload` to a Guix VM on the TrueNAS box (40
  cores), if one build machine isn't enough.
