# Argbed: a hardened, private, minimal, modular kickstart for Fedora

A kickstart is the file that tells anaconda, Fedora's installer, what to
do. Argbed assembles one for the Fedora 44 network installer from small
modules, and the system it installs is:

- LUKS2-encrypted root; `/boot` and the EFI system partition (ESP) stay
  plain and mount nodev, nosuid, noexec.
- Signed unified kernel images (UKI: kernel, initramfs and command line
  in one signed file) as the boot path, through the stock shim (the
  Microsoft-signed first stage) and a machine key enrolled as a Machine
  Owner Key (MOK); with Secure Boot on, nothing unsigned boots. GRUB
  stays installed for shim's sake but has no boot entry and no
  configuration.
- SELinux enforcing, with confined users and a locked root account.
- Default-drop nftables for ingress and egress, loaded before the
  network comes up on every boot. During the installation itself no
  filtering is possible: the Fedora 44 netinstall media ships no
  netfilter kernel module, so the kickstart's pre-install script
  (`%pre`) reads the listening sockets from /proc/net and halts for
  confirmation if any TCP service is reachable.
  Use a trusted network for the install.
- systemd-networkd and iwd instead of NetworkManager, with randomized
  MACs and RFC 7844 anonymized DHCP.
- Updates installed at boot, before login, never during a session.
- A sway Wayland desktop.
- Microphones and cameras disabled: no capture node in pipewire, the
  v4l and ALSA capture device nodes closed to every unprivileged
  process, and the uvcvideo driver never loaded.
- No `@core`: every package on the system is named in a module, a hard
  dependency of one, or one of the installer's own additions (`grubby`
  and `grub2-tools-extra` with `mtools` for its bootloader step, `langpacks-en` with
  the font packages it pulls in for the chosen locale).

**No warranty.** This kickstart destroys the disk it is pointed at, locks
the root account and enrolls a Secure Boot key. It is provided as is,
without warranty of any kind, and its author is not liable for lost
data, a machine that no longer boots, or any other damage arising from
its use (Apache License, sections 7 and 8). Read every module before
installing, and test in a virtual machine first.

## Build & use

```sh
cp build.conf.example build.conf   # per-machine values (optional)
./build.sh                         # ks.d/*.cfg -> argbed.cfg + validation
```

The validation step needs `ksvalidator` from `pykickstart`
(`sudo dnf install pykickstart`); without it `./build.sh` warns and
skips it.

Per-machine values: defaults < `build.conf` < environment
(`KS_HOSTNAME`, `KS_ADMIN_USER`, `KS_DESKTOP_USER`, `KS_BOOT_LABEL`,
`KS_TIMEZONE`, `KS_FIRMWARE`, `KS_RESOLVERS`), as in `KS_HOSTNAME=laptop
./build.sh`. Values are validated; `@KS_...@` tokens in modules are
substituted at build time. `KS_FIRMWARE` names the firmware packages for
your GPU, WiFi, Bluetooth and audio hardware and your CPU's microcode
(the list is in `build.conf.example`): Fedora ships them as weak
dependencies of `linux-firmware` or as separate packages, and this
kickstart installs no weak dependency, so unnamed hardware runs without
firmware, and the build warns when no microcode package is named.
`KS_RESOLVERS` names the DNS resolvers (Cloudflare's by default) that the
installed system and the installer use and that the firewall pins port
53 to. Keep `build.conf` out of any published copy: it describes your
machine. `KS_BOOT_LABEL` (default
`Fedora Linux`) is the firmware boot-menu entry name. It sits in NVRAM,
visible to anyone at the boot menu pre-auth, so the default is a generic
name with nothing of this machine in it, safe to reuse identically on
any number of disks: booting never depends on the label, and entry
cleanup never matches by it. Install-time entry cleanup matches exclusively by
GPT partition UUID: `%pre` records the chosen disk's partition UUIDs
before the wipe, and the post-install scripts (`%post`) delete only entries referencing those
(previous installs of *that disk*, whatever they were labeled) plus
anaconda's own grub entry (new ESP's UUID). Other disks' entries are
never touched, attached or unplugged. Distinct labels (`Fedora A`) are
optional, only if *you* want to tell entries apart. The same principle covers the unencrypted
ESP: UKI filenames use a fixed `fedora` entry token instead of
kernel-install's default (the confidential machine-id). During install,
`%pre` lists existing NVRAM boot entries and lets you delete stale ones
(renamed labels, wiped disks) by number; entries of earlier installs on
the chosen disk are removed automatically, matched by partition UUID.

Boot a Fedora **netinstall (Everything)** image in **UEFI mode (x86_64)**
and pass the generated file, as in `inst.ks=hd:LABEL=KSUSB:/argbed.cfg`,
where `KSUSB` is the filesystem label of the stick prepared below.

## Kickstart USB

The stick that carries `argbed.cfg` can be LUKS-encrypted as a whole:
the netinstall's initrd unlocks it before anaconda reads the kickstart
(dracut's crypt hooks and dm-crypt are on the Fedora 44 netinstall
image, release 44-1.7; the prompt
comes before any network is up), so the kickstart cannot be read or
altered without the passphrase, and a `payload/` directory next to it
travels the same way. Prepare it on a running system:

```sh
sudo cryptsetup luksFormat --type luks2 /dev/sdX      # whole stick, no partition table
sudo cryptsetup open /dev/sdX ksusb
sudo mkfs.ext4 -L KSUSB /dev/mapper/ksusb
sudo mount /dev/mapper/ksusb /mnt
sudo cp argbed.cfg /mnt/
sudo mkdir -p /mnt/payload/keep                       # files for /root/keep
sudo cp -a /var/lib/bluetooth /mnt/payload/bluetooth  # pairings, same machine only
sudo umount /mnt && sudo cryptsetup close ksusb
udevadm info -q property /dev/sdX | grep ID_SERIAL_SHORT   # serial, if the stick has one
sudo cryptsetup luksUUID /dev/sdX                          # UUID, always present
```

Boot the netinstall and name the stick on its kernel line, either way
followed by `inst.ks=hd:LABEL=KSUSB:/argbed.cfg`:
- `rd.luks.serial=<a few characters of ID_SERIAL_SHORT>`, matched as
  a substring of that property on devices carrying a LUKS header, so
  four to six characters are enough, and the serial survives
  re-formatting the stick. Many sticks have no real serial: the
  property is then absent (only a generic `ID_SERIAL`), and only the
  UUID form works;
- `rd.luks.uuid=<the full UUID>`: works for every stick; the UUID
  changes with every `luksFormat`.

The label is the one inside the encrypted volume. dracut asks for the
passphrase, then finds the kickstart; type it within dracut's retry
window (about three minutes by default; `rd.retry=900` extends it).
`205-carry-over` copies `payload/keep` to `/root/keep` (made root-only)
and, from `payload/bluetooth`, only the bond keys into
`/var/lib/bluetooth`: each bonded device's `info` file and the
controller's identity resolving key; caches, GATT tables and adapter
state stay on the stick. A plain (unencrypted) stick works the same way,
and the installer prints a warning that the payload was read in clear.

Network is needed **during installation only** (packages come over HTTPS,
every metalink is pinned to https-only mirrors); the first boot needs no
network. The connection is asked for **last of the `%pre` prompts**
(anaconda's own LUKS passphrase prompt follows): leave the cable out (or
WiFi unjoined) until then. From that
point the installer stays online until it reboots, through the package
fetch and every `%post`. If no connection is up,
`%pre` offers ethernet-retry or an interactive WiFi join
(installer-only; the credentials do not survive the reboot, and the installed
system uses iwd, fresh).

Interactive moments, in order:
1. **%pre (tty3):** pick the target disk from a full partition listing
   and confirm destruction with `YES` (200); the USB payload is copied
   without prompting (205); optional wipe of the disk: LUKS headers of
   earlier installs, the drive's own erase (NVMe format / ATA secure
   erase; seconds for a crypto erase, hours otherwise), shred passes
   (one full write of the disk per pass) (210);
   Secure Boot check, stale firmware boot entries to delete by number,
   Secure Boot keys of earlier installs to delete by number (boot label,
   creation date and fingerprint shown), and the one-time MOK password (500;
   Secure Boot off or absent needs a typed YES, and firmware with **no**
   Secure Boot implementation then skips the key steps entirely, since
   mokutil cannot enroll anything there); finally the exposure reading
   and the network check (999).
2. **anaconda:** prompts for the LUKS passphrase (never stored in a file).
3. **First boot:** blue *MOK management* screen appears before the OS
   and waits for a key: Enroll MOK, Continue, Yes, then the password from
   step 1; Delete MOK appears on the same screen when keys were named
   for deletion. An unanswered request stays queued and the screen
   returns on the next boot. **With Secure Boot on, deleting the
   enrollment request leaves the machine unbootable until enrolled**
   (recovery: live USB, see `/root/uki-notes.txt`). On firmware without
   SB support this step does not exist.
4. **Then (tty1):** both users' passwords, followed by module fragments
   in number order: the MOK enrollment status (500; it asks for a new
   one-time password only when the enrollment request is gone), TPM2 PIN
   enrollment if optional/510-tpm-luks is enabled, the SELinux
   confined-user mapping (910) and the reminder to run `verify-install`
   (990). The firstboot unit then **shreds** anaconda's kickstart copies
   (they can embed storage secrets), its fragments and itself, and reboots.
5. **Every boot after that (tty1):** the boot updater
   (`450-auto-updates`) downloads and installs pending updates before
   login. Ctrl+C during the wait/download phase skips to login for that
   boot; the install itself cannot be interrupted, and the system
   reboots by itself after every update, so nothing updated keeps
   running. Offline boots continue to login after ~30 s.
6. **After the first login:** `sudo verify-install` re-checks the
   security properties the modules set (SELinux, firewall, boot chain,
   MOK, lockdown, capture nodes, confined users, ...), prints OK/FAIL, and on
   success offers to shred the remaining install logs
   (`/root/ks-post-*.log`, `/var/log/anaconda`). Keep them until it
   passes: they are the debugging trail. Re-runnable as a health check.

## Layout

```
build.sh             assembler: token substitution + validation
build.conf(.example) per-machine values; build.conf never ships
verify.sh            resolves the package set against live repos
tests.sh             checks that need no installation, in scratch space
ks.d/                active modules, concatenated in lexical order
optional/            drop-ins; enable with: cp optional/NNN-x.cfg ks.d/
argbed.cfg           generated output, never edited by hand
ks-verify.log        verify.sh's resolution log, generated
argbed.svg           project icon
LICENSE              Apache-2.0
```

| Band    | Purpose                                                      |
|---------|--------------------------------------------------------------|
| 000-099 | installer behavior, repos                                    |
| 100-199 | core system commands (lang, network, selinux, ...)           |
| 200-299 | storage (%pre + %include), USB payload carry-over, disk wipe |
| 300-399 | explicit base %packages (`--nocore`)                         |
| 400-499 | system-configuration %post (dnf policy, network, firewall, hardening, services, updates) |
| 500-599 | boot chain at 500-549 (500 UKI, 510 TPM2 LUKS); hardware at 550-599 (550 bluetooth, 560 usbguard, 570 nvidia) |
| 600-699 | VPN, one decade per provider: client at x0, kill switch at x5 |
| 700-799 | desktop session (/etc/skel shell, sway + session add-ons, audio) |
| 800-899 | applications                                                 |
| 900-999 | users (900, 910); firstboot (980), verify (990) and the installer's network step (999, the last `%pre`) hold the end |

Modules that must run last sit at the end of the number space (980,
990, 999), so a new module sorts before them by default; each band's
spare numbers are the growth room. A module with a `%pre` is numbered
below 999: the network step there is the first point where the install
needs a connection, and no `%pre` runs after it.

Optional modules:

- 510 TPM2+PIN LUKS keyslot for TPM-equipped machines; runtime-skips
  without one.
- 560 usbguard: USB devices not present during the installation are
  blocked.
- 570 NVIDIA proprietary driver from RPM Fusion, legacy series
  580xx/470xx included, modules signed with the machine key, so it
  requires firmware with Secure Boot support (guarded); sway wrapper
  included. Intel/AMD/nouveau need nothing: the module no-ops and
  writes /root/gpu-report.txt when no NVIDIA GPU is present. nouveau
  drives NVIDIA cards too but cannot raise clocks on Maxwell/Pascal-era
  cards. After a kernel update the next boot rebuilds the module and
  may run without the driver once. The one machine key then signs both
  the boot chain and the modules and becomes readable by the build
  account of akmods, Fedora's out-of-tree module builder; a second key
  would not improve on that, since shim
  trusts every enrolled key alike and using either needs root or the
  akmods account. Expect about 1 GiB of hard dependencies: the CUDA
  runtime libraries, nvidia-settings and the build toolchain akmods
  keeps for kernel updates.
- 600 openvpn: per-server configs run as SELinux-confined
  `openvpn-client@<name>` units; setup in "VPN" below.
- 605 OpenVPN kill switch: a second nftables output chain pins all
  egress to OpenVPN's tun interface, so tunnel down means offline by
  design; requires 600 and covers only it, WireGuard interfaces are not
  matched.
- 610 WireGuard: in-tree kernel module, Fedora-signed, no MOK/akmods;
  configs run as SELinux-confined `wg-quick@<name>` units.
- 615 WireGuard kill switch: the same egress restriction for wg*
  interfaces; requires 610; never together with 605, since each kill
  switch drops the other's tunnel. A second OpenVPN can ride nested inside the tunnel,
  split or double hop: recipes in "VPN" below.
- 730 screenshots and screen sharing for sway.
- 740 playerctl media keys.
- 820 chromium, hardened by managed policy like Firefox plus two launch
  switches in Fedora's `chromium.conf`: telemetry, sync, autofill, spell
  check, JIT/optimizer, ad auction APIs and background mode off,
  third-party cookies blocked, HTTPS-only, DuckDuckGo search, DNS over
  HTTPS (DoH) off.
- 830 mpv with RPM Fusion's libavcodec-freeworld, the H.264/HEVC
  decoders Fedora's ffmpeg-free lacks.
- 840 freerdp.
- 850 Claude Code from the official Anthropic dnf repository,
  signing-key fingerprint pinned (every key in the downloaded file must
  match it); telemetry, crash reporting and
  self-updates off via managed settings, so dnf is the only update
  channel.

## Module rules

- Every module is self-contained: sections it opens, it closes with `%end`.
- Modules may declare their own `%packages` (pykickstart merges sections
  additively), but **every `%packages` header must repeat exactly**:
  `%packages --nocore --exclude-weakdeps --excludedocs --inst-langs=en_US:en`
  since a later plain header silently resets all flags to defaults.
- No groups, no weak deps, no docs, English locales only. Anything needed
  must be named explicitly, which is why `linux-firmware`,
  `mesa-dri-drivers`, `polkit`, `dbus-broker` etc. appear by name.
- `%post` scripts run in order with `set -Eeuo pipefail`, an ERR trap that
  prints the failing command, and `--erroronfail`: any unguarded failure
  aborts the install and names the command that caused it. `|| true` only
  where a failure is acceptable.
- User config goes to `/etc/skel` in a 700-899 module; `useradd` in
  `900-users.cfg` copies it. Optional modules may *append* to skel files
  from earlier modules (see 730-screenshot appending sway keybindings).
- Build-time tokens available in any module: `@KS_HOSTNAME@`,
  `@KS_ADMIN_USER@`, `@KS_DESKTOP_USER@`, `@KS_BOOT_LABEL@`,
  `@KS_TIMEZONE@`, `@KS_FIRMWARE@`, `@KS_RESOLVERS@` (build fails on
  unknown tokens).
- Per-module logs land in `/root/ks-post-*.log` on the installed system.
- A module writes its own checks for `verify-install` into
  `/etc/verify.d/NNN-name.sh`, with `chk` and `sh_chk` available; 990
  sources the fragments in name order, so a removed module takes its
  checks with it and a new one never touches 990.

## The --nocore base: read before removing packages

`ks.d/300-packages.cfg` lists the entire base. Some entries look optional
and are not:

- **authselect** generates `/etc/pam.d/system-auth`; without it login,
  sudo, passwd and swaylock all fail. `400-dnf` also runs
  `authselect select local with-faillock --force` as a safety net.
- **systemd-pam** provides `pam_systemd.so`, which registers logind sessions and sets
  `XDG_RUNTIME_DIR` at login. Only a *Recommends* of systemd, and the PAM
  stack skips the module silently when it is missing (`-session
  optional`): logins still "work", but no Wayland session can start, no
  `systemctl --user`, no user poweroff/reboot.
- **cryptsetup**: dracut only includes LUKS support in the initramfs if
  it is installed; without it the encrypted root never boots.
- **fedora-repos / dnf5 / rpm**: no updates without them.
- **glibc-langpack-en, tzdata, kbd**: locale, timezone, console keymap.
- **linux-firmware** carries only the base set. Fedora ships GPU, WiFi,
  Bluetooth and audio firmware as subpackages that `linux-firmware` merely
  recommends, and CPU microcode and the SOF audio DSP firmware as separate
  packages; weak dependencies are never installed here: name yours
  in `build.conf` (`KS_FIRMWARE`, list in `build.conf.example`), or that
  hardware runs without firmware and the CPU on its factory microcode.
  After the first boot,
  `journalctl -k | grep -i firmware` names anything the kernel asked for
  and did not find; `/root/gpu-report.txt` (optional/570-nvidia) names
  the GPU.
- No man pages ship (`--excludedocs`, and no `man-db`); no `vi` (nvim is
  wired into visudo/$EDITOR by `800-neovim`); no `ping` (the egress
  firewall drops ICMP; the rule is a comment away in `420-firewall`, and
  `iputils` has to be added to `300-packages`).

**Test a --nocore change in a VM before real hardware.** If something is
missing it usually fails visibly (install abort or no login); check
`/root/ks-post-*.log` and add the package to the right module.

## Boot-chain security (UKI-only, GRUB inert)

- **Secure Boot expected**: `%pre` warns and requires a typed `YES` if
  firmware SB is off. Microsoft/Fedora firmware CAs are never touched.
  Two degraded cases, both read from the `SecureBoot` efivar: SB
  *switched off* still enrolls the key (the machine stays one firmware
  toggle away from a verified chain); firmware with *no SB
  implementation* (variable absent) can never enroll: mokutil refuses
  every enrollment operation there, so the MOK steps are skipped and the
  chain loads unverified. `verify-install` prints a WARN on every
  run in both cases instead of a permanent FAIL.
- **Signed UKIs (500-uki-boot)**: kernel + initramfs + cmdline in one PE
  binary, signed with a machine-local key living only on the encrypted
  root, verified through the *stock* MS-signed shim via MOK. Chain:
  firmware -> shim -> systemd-boot (sd-boot, signed, under the name
  grubx64.efi, shim's default second stage) -> UKI (signed). sd-boot's editor is
  off; the cmdline is inside the signature. Kernel updates build and sign
  UKIs via Fedora's *native* `kernel-install layout=uki` flow; the
  shim/sd-boot copies refresh on every kernel install.
- **The GRUB boot path is inert.** The `grub2-efi-x64` *package* must
  stay because shim-x64 hard-requires it; removing it would take shim,
  the head of the chain. GRUB has no boot entry, no grub.cfg and masked
  kernel-install plugins, so no boot reaches it; the stock
  `EFI/fedora/shimx64.efi` and `grubx64.efi` stay on the ESP, and a
  firmware with a file browser can start them into a GRUB prompt,
  Secure Boot on or off; under Secure Boot that GRUB loads only what
  shim verifies. `grub2-tools` comes with `grub2-efi-x64`; `grubby` is
  not in the closure the modules name: the installer's bootloader step
  brings it, and systemd-udev's dependency on it is conditional, a
  version floor that binds only while it is installed.
  The system keeps exactly one kernel: after an update, the previous
  kernel's UKI stays bootable for one boot (the sd-boot menu is hidden;
  hold a key during boot to pick it), then whichever kernel booted
  successfully survives (`prune-old-kernels.service`).
  Everything else is live-USB recovery, documented in
  `/root/uki-notes.txt`.
- **MOK enrollment is queued during installation** with a password chosen
  in `%pre` (staged via installer tmpfs, shredded after use). First boot
  shows MokManager, waiting for a key (`MokTimeout` -1); enrolling there
  is mandatory when SB is on. Every enrolled key stays in the firmware's
  small variable storage until deleted (too many and the firmware may
  stop booting), so `%pre` lists this kickstart's enrolled keys with
  boot label, creation date and fingerprint and queues deletion of the
  ones you name, handled on the same screen; `verify-install` lists the
  enrolled machine keys (this system's marked) and `/root/uki-notes.txt`
  has the manual procedure. The label is the key's second subject field
  (OU), so distinct labels tell the keys of several disks apart.
- **TPM2 + PIN LUKS keyslot (optional/510-tpm-luks)** for TPM-equipped
  machines: enrolled at first boot, bound to the TPM's Secure Boot state
  register (PCR 7, stable across kernel updates), passphrase kept as
  recovery. A keylogged PIN is useless
  without this machine's TPM in an unchanged Secure Boot state.
  **Rule: if the machine unexpectedly asks for the
  recovery passphrase instead of the PIN, stop and investigate from a
  live USB.** UKI and TPM are independent.
- **/boot and the ESP mount nodev,nosuid,noexec** (ESP also umask=0077).
- Kernel cmdline includes `lockdown=confidentiality` and
  `module.sig_enforce=1` (plus `iommu.strict=1` and the init_on_* set,
  which cost some throughput and are the first to drop if that matters
  more than hardening).
  Consequences: no bpftrace/perf-style kernel introspection (none
  installed), and *unsigned kernel modules never load*; optional/570-nvidia
  signs its modules automatically. `efi=disable_early_pci_dma` stays
  opt-in (a commented-out line in `200-storage.cfg`): it can hang rare
  firmware, and with a signed cmdline there is no boot-prompt escape
  hatch, so test it in a VM first.
- **Residual risk**: firmware-level implants and attacks below
  the UEFI trust anchor (vendor BootGuard territory).

## Confined users (910-confined-users)

Desktop user runs as SELinux `user_u`, admin as `staff_u` with sudo
transitioning to `sysadm_t`, with no `unconfined_t` logins: an account
added later maps to `user_u` until the admin maps it otherwise. Applied
at first boot before any login. Sway under `user_u` is an uncommon
pairing: watch `sudo ausearch -m avc -ts recent`. Rollback, as the
admin user and in this order: `sudo semanage login -m -s unconfined_u
-r s0-s0:c0.c1023 __default__`, `sudo semanage login -d <desktop
user>`, `sudo semanage login -d <admin user>`, `sudo rm
/etc/sudoers.d/selinux-role`, then log out and back in. If the admin
login itself misbehaves, a plain tty login (Ctrl+Alt+F2) runs the same
commands; the last resort is a live USB with chroot.
The policy denies `user_t` the namespace capabilities and mounts
bubblewrap needs, and GTK loads icons through bubblewrap-sandboxed
glycin loaders; the local module `bwrap-user.cil` (910) grants exactly
the denials recorded from a bubblewrap run in permissive mode: the
capabilities inside the user's own namespaces, netlink route writes,
and the mount operations on the filesystem types bubblewrap uses, so
file dialogs work under the desktop user.
Repeated failed logins lock the account for a time (authselect's
`with-faillock`).

## VPN (optional 600, 605, 610, 615)

**OpenVPN (600).** One server config per file in
`/etc/openvpn/client/<name>.conf`, root:root 0600 together with every
file it references: that directory's SELinux label is what lets the
confined daemon read them, and a config's `verify-x509-name` pins one
server, so configs are never merged. `sudo systemctl start
openvpn-client@<name>` connects now, `sudo systemctl enable --now
openvpn-client@<name>` on every boot. A boot-time connect cannot answer
a password prompt: point `auth-user-pass <file>` at a two-line file
(username, then password), root:root 0600 in the same directory; manual
starts ask through systemd-ask-password. openvpn applies server-pushed
DNS to the static resolv.conf by default; either put the pushed
resolver IPs into the pinned DNS rule (`KS_RESOLVERS` at build time,
`/etc/sysconfig/nftables.conf` on a running system) or refuse the
push with `pull-filter ignore "dhcp-option DNS"`. After a crash the
pushed resolvers linger: reconnect, or restore the file by hand.

**WireGuard (610).** One config at `/etc/wireguard/wg0.conf`, root:root
0600; `sudo systemctl start wg-quick@wg0` connects now, `sudo systemctl
enable --now wg-quick@wg0` on every boot; the interface takes the
config file's name. Provider configs need two edits: delete the `DNS=`
line (applying it needs a resolvconf command this system does not
ship, and wg-quick aborts; the static resolv.conf rides through a full
tunnel, or write the provider's in-tunnel resolver into
`/etc/resolv.conf` by hand and put its IP into the pinned DNS rule, as
above), and
delete IPv6 entries from `Address=` and `AllowedIPs=` (IPv6 is off and
wg-quick aborts on a v6 address). Keep `Endpoint=` an IP: the unit
retries hostname resolution forever.

**The egress firewall default-drops.** Add each endpoint to
`420-firewall.cfg`, pinned by IP and port as read off the config's
`remote` or `Endpoint =` line (the addresses are RFC 5737 documentation
values). On an installed system the live ruleset is
`/etc/sysconfig/nftables.conf`, and `systemctl restart nftables` loads
it and restarts networkd with it:

```
ip daddr { 203.0.113.7, 203.0.113.9 } udp dport 1194 accept comment "OpenVPN"
ip daddr 203.0.113.7 udp dport 51820 accept comment "WireGuard"
```

**Kill switches (605, 615).** Each appends a second output chain that
confines the allowlist to the tunnel; the endpoint must be accepted in
both chains, so fill in the `vpn_endpoints` set and the handshake port
in the module as well. The set ships empty, and empty it blocks the
handshake: an unedited install is offline, never leaking. `remote` and
`Endpoint=` must be IPs, since off-tunnel DNS is blocked. A captive
portal cannot be answered while the kill switch is active; lift it until the
next nftables restart or reboot with `sudo nft delete table inet
killswitch` (605) or `sudo nft delete table inet killswitch_wg` (615).

**Nested OpenVPN inside WireGuard (615 with 600).** The inner handshake
leaves through wg*, so the inner operator sees the outer exit address.
Accept the inner endpoint in `420-firewall.cfg` plus the inner VPN's own
ports there, scoped to the tunnel, as in `oifname "tun0" ip daddr
10.0.0.0/8 tcp dport 22 accept`; the inner endpoint is not added to
`vpn_endpoints` (the off-tunnel list), and 605 stays disabled.

- *Split*: only the inner VPN's networks use it, everything else leaves
  through wg* directly. Inner config, one route line per network it
  serves, and nothing else (such routes can cover neither endpoint):

  ```
  route-nopull
  route 10.0.0.0 255.0.0.0
  ```

- *Double hop*: everything goes through the inner VPN, then wg*. Inner
  config (its routes land in wg-quick's table, where they beat the wg*
  default for unmarked traffic; wg*'s own packets carry the mark and use
  the main table, so neither tunnel captures the other's endpoint):

  ```
  route-nopull
  route-table 51820
  route 0.0.0.0 128.0.0.0 vpn_gateway
  route 128.0.0.0 128.0.0.0 vpn_gateway
  ```

  and in the wg config's `[Interface]` (`FwMark` pins wg-quick to table
  51820 across restarts; the route sends the inner handshake into the
  tunnel and vanishes with the interface; 198.51.100.7 stands for the
  inner VPN's endpoint):

  ```
  FwMark = 51820
  PostUp = ip -4 route add 198.51.100.7/32 dev %i
  ```

  `route-nopull` refuses every pushed route, resolver and
  redirect-gateway (that one would also add a host route to the inner
  server around wg*). Boot order: openvpn-client@ instances start after
  every enabled wg-quick@ instance and after the boot updater, so
  updates ride the outer tunnel only; interface down leaves both VPNs
  unreachable and the kill switch drops everything.

## Verification status

Every module has been through a real installation except the optional
510, 560 and 570, which have not been installed on hardware: 510 and
560 pass the build, `ksvalidator` and the dependency resolution below;
570 installs through dnf in `%post` (as 830 and 850 do), so `verify.sh`
never sees its packages and only the build and `ksvalidator` cover it.
Edits made after an install are covered by the build, `ksvalidator` and
`tests.sh` until the next one.

Checked against live Fedora repos (dnf5 `--installroot` dry run, weak deps
off): the full module set resolves to a ~670-package closure with no
conflicts; `authselect`, `pam` + `cracklib-dicts`, `audit`+`audit-rules`,
`cryptsetup` + `systemd-udev` (systemd-cryptsetup), `polkit`,
`dbus-broker`, `selinux-policy-targeted` and `mokutil` are all present;
every daemon a dependency brings in is disabled by a module (systemd-homed
by 440, the avahi daemon that chromium's nss-mdns chain pulls in by 820
itself; everything else avahi/cups in the closure is libraries) or kept
with its reason in 440's header (rtkit-daemon for pipewire's realtime
scheduling, systemd-oomd for memory pressure above the zram swap), and no
`firewall` kickstart command is used because anaconda installs firewalld
for any such command (`verify-install` checks the package is absent).
Firefox hard-requires xdg-desktop-portal, which in turn requires
geoclue2 and fuse3: D-Bus-activated only, no enabled units.
The nftables ruleset is kernel-validated (`nft -c` in a network
namespace). SELinux
labels of module-written files are checked against the targeted policy:
a created file inherits its directory's type, and the three paths whose
canonical context differs from that (`/etc/resolv.conf`,
`/etc/hostname`, `/etc/systemd/coredump.conf.d`) are restorecon-pinned
where written and re-checked by `verify-install`. Re-verify
after changing packages:

```sh
./build.sh && ./verify.sh
```

Dependencies: dnf always installs *hard* dependencies (a missing
one fails the transaction; `verify.sh` proves this ahead of time). What
this project refuses is *automatic weak deps* (Recommends): that is
where the unrequested packages come from. When something misbehaves, audit what it wanted
with `dnf repoquery --recommends <pkg>` and add the pieces you actually
need, by name, to the right module.

## Deliberate trade-offs (know these before changing them)

- **Egress allows only DHCP/DNS/NTP/443.** Port 80 is blocked: captive
  portals fail, and a third-party repo without https mirrors fails until
  you uncomment the rule in `420-firewall.cfg`. Port 22 is blocked too:
  git remotes over HTTPS work, SSH ones need the port 22 switch in the
  same file. The Fedora and RPM Fusion
  repos never try one: their metalinks carry `protocol=https`, appended
  to the repo files for the lifetime of the system (400, 570, 830). DNS
  egress is pinned
  to the static resolvers: port 53 to anywhere else is dropped as an
  exfiltration channel. VPN endpoints must be added there pinned by IP
  and port (read both off your config's `Endpoint =` / `remote` lines).
  Optional modules 605/615 pin all egress to the VPN tunnel
  (OpenVPN/WireGuard) on top of this: tunnel down means offline (only
  DHCP renewals and the handshake to your listed endpoint IPs leave the
  bare NIC), by design. The ruleset is a hard dependency of networkd: if
  it fails to load, the machine comes up offline, not unfiltered.
- **Every online boot updates before login** (`450-auto-updates`): boot
  time grows by the size of the day's updates, and an update day adds one
  more reboot. Ctrl+C at the updater skips it for that boot; every login
  prompt waits for it and the stock dnf metadata timer is disabled, so
  sessions and update traffic never overlap.
- **DNS is a static file** naming `KS_RESOLVERS` (Cloudflare's by
  default), so VPN clients can replace it (a replacement resolver's IP
  must also be in the pinned DNS rule of `420-firewall.cfg`, filled from
  the same token); DHCP-provided DNS and pushed
  routes are ignored (the gateway is still taken).
  systemd-resolved is masked:
  not installed, and Fedora's preset would auto-enable it if a future
  dependency pulled it in; the mask outlives that. This covers the
  *installation* too: `%pre` pins the installer's DNS to the same
  resolvers (with automatic revert on networks that block outside DNS).
  Firefox's
  built-in DoH is disabled by policy so a VPN captures all queries;
  flip it in about:preferences if you run without one.
- **IPv6 disabled** via sysctl, core dumps off via sysctl, a
  systemd-coredump drop-in and PAM limits (`430-hardening.cfg`).
- **DNF countme is off** for every repository (`400-dnf`).
- **Root locked**; rescue-mode sulogin will not accept a locked
  root: recovery = live USB + LUKS passphrase + chroot. There is also no
  rescue initramfs (`dracut-config-rescue` not installed).
- **UEFI x86_64 only**: `%pre` aborts on BIOS/CSM; the bootloader
  package in `300-packages.cfg` is arch-specific (`shim-x64`; anaconda
  adds `grub2-efi-x64` itself).
- **Bluetooth pairable only inside a `bluetoothctl` session** (bluez makes
  the controller pairable while a pairing agent is registered and drops
  it when the agent goes; never discoverable unless switched on there,
  180 s timeout). Delete `ks.d/550-bluetooth.cfg` for no stack at all.
  Bluetooth Low Energy traffic uses resolvable private addresses
  (`Privacy = device`); classic (BR/EDR) links carry the controller's
  fixed address by protocol.
- **Capture devices are closed at the node** (`430-hardening.cfg`): the
  uvcvideo driver never loads (`install uvcvideo /bin/false`), and v4l
  and ALSA capture nodes are mode 0000 with the seat ACL withheld, so
  no unprivileged program opens them; pipewire creates no capture node
  (720). A camera works again for programs that open V4L2 directly once
  `/etc/modprobe.d/no-webcam.conf` and
  `/etc/udev/rules.d/72-privacy-capture.rules` are removed and the
  system rebooted; pipewire clients also need 720's capture rule moved
  away. The node closure has not been through an install on a card whose
  audio profiles come from UCM (SOF laptops): pipewire's card-profile
  probe opens every capture device of a profile and drops the whole
  profile when one fails to open (its ALSA card-profile source), so such
  a card may be left with no playback profile, while HDA cards keep their
  output-only profiles; neither outcome has been exercised on an install
  yet.
- User namespaces stay enabled: Firefox's sandbox requires them.
- **Browsers are hardened by policy** (810, 820): telemetry, sync and
  autofill off, third-party cookies rejected, HTTPS-only, DoH off;
  Chromium also has JIT and background mode off, and Firefox ships with
  JIT off as a changeable default. Firefox ships uBlock Origin from Fedora's own
  package in enforced medium mode (third-party scripts and frames
  blocked, allowed per site from its panel); rules saved with the
  panel's padlock last until the next start, when the policy re-applies
  its global rules, while temporary allowances work as usual. Firefox's
  file picker is GTK's own and locked, because the portal file chooser
  needs a backend package the base modules lack; Do Not Track stays
  off, since Global Privacy Control replaces it and the DNT header adds
  a fingerprinting bit; list-based Safe Browsing stays on in both
  browsers, with Chromium's proxied real-time lookups of standard
  protection off by policy. Both search with DuckDuckGo, fixed by policy.
  Chromium's spell check is off because its dictionaries come only from
  Google; Firefox's DRM is off and locked because its Widevine module
  would be fetched from Google. 820 edits Fedora's `chromium.conf`, a
  noreplace config file, so Fedora's later changes to it arrive as
  `.rpmnew`. Measured with Firefox 159 and Chromium 156 on fresh
  profiles over two minutes, the policies read from the browsers' own
  policy pages and the locked preferences applied to the profile:
  Firefox contacts only Mozilla's remote settings (certificate
  revocations, blocklists, tracking-protection lists), the Safe Browsing
  lists and uBlock's list sources; Chromium contacts only its component
  updater (certificate revocation data among the components, some
  fetched over plain HTTP), the Safe Browsing lists and an
  unauthenticated account-list request at start.
- Third-party software (NVIDIA driver, mpv's RPM Fusion decoders, Claude
  Code) is opt-in only, each with its trust chain documented in its
  module: signatures are verified against keys Fedora ships or a pinned
  fingerprint before anything installs, never trusted on first use.

## Name, copyright and license

*Argbed* (ARG-bed) was the Sasanian title of the commander who held a
citadel, the office that outranked the army's generals, and the one
Ardashir held before he founded the empire.

Copyright 2026 Amir Ghayour. Licensed under the Apache License, Version 2.0
(see `LICENSE`). "Fedora" is a trademark of Red Hat, Inc.; this project
is not affiliated with or endorsed by the Fedora Project.
Website: <https://argbed.com>. Author: <https://amirghayour.com>.
