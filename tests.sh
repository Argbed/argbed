#!/usr/bin/env bash
# Checks that need no installation: build.sh's refusals and output
# handling, every %pre and %post of a scratch build through bash -n, the
# updater's reboot path with stub tools, the verify runner's artifact
# listing, the MOK and TPM fragments with stub tools and the kill-switch
# guard. Writes nothing into the tree and opens no connection: everything
# happens under a mktemp directory.
set -uo pipefail
cd "$(dirname "$0")"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "  OK    $1"; }
fail() { echo "  FAIL  $1"; fails=$((fails+1)); }
section() { awk -v s="$1" -v e="$2" 'index($0, s)==1 {p=1; next} p && $0==e {exit} p' "$3"; }
mkdir -p "$T/bin"
stub() { printf '#!/usr/bin/bash\n%s\n' "$2" > "$T/bin/$1"; chmod 755 "$T/bin/$1"; }

echo "--- build.sh ---"
mkdir -p "$T/tree/ks.d"
cp ks.d/*.cfg "$T/tree/ks.d/"; cp build.sh "$T/tree/"
build() { (cd "$T/tree" && env KS_ADMIN_USER="$1" KS_DESKTOP_USER="$2" "${@:3}" ./build.sh >/dev/null 2>"$T/build.err"); }
# a refusal is the named one, not any failure
refused() { ! build "${@:2}" && grep -q "$1" "$T/build.err"; }
refused "system account" adm me && pass "a system account name is refused" || fail "a system account name is refused"
refused "group name" wheel me && pass "a system group name is refused" || fail "a system group name is refused"
refused "invalid KS_RESOLVERS" admin me KS_RESOLVERS="dns.example" && pass "a resolver that is not an IPv4 address is refused" || fail "a resolver that is not an IPv4 address is refused"
refused "invalid KS_RESOLVERS" admin me KS_RESOLVERS="999.1.1.1, 1.0.0.1" && pass "an octet above 255 is refused" || fail "an octet above 255 is refused"
if build admin me && [ -f "$T/tree/argbed.cfg" ] && ! ls "$T/tree"/argbed.cfg.* >/dev/null 2>&1; then
    pass "the tree builds and leaves no temp file"
else
    fail "the tree builds and leaves no temp file"
fi
grep -q '{ 1.1.1.1, 1.0.0.1 } udp dport 53' "$T/tree/argbed.cfg" && pass "the default resolvers reach the firewall rule" || fail "the default resolvers reach the firewall rule"
printf '%s\n' '# 101-x: a test module' 'lang @KS_Boot_Label@' > "$T/tree/ks.d/101-x.cfg"
build admin me && fail "an unreplaced token is refused" || pass "an unreplaced token is refused"
rm -f "$T/tree/ks.d/101-x.cfg"

echo "--- every section and embedded script of the build ---"
awk -v out="$T/sec" '/^%(pre|post)/{n++; f=out "-" n ".sh"; s=1; next} /^%end/{s=0; close(f); next} s{print > f}' "$T/tree/argbed.cfg"
for f in "$T"/sec-*.sh; do
    awk -v out="$f" 'e==0 && /<< '\''[A-Z_]+'\''$/ {t=$0; sub(/.*<< '\''/,"",t); sub(/'\''$/,"",t); e=1; k++; g=out ".emb" k; next} e==1 && $0==t {e=0; close(g); next} e==1 {print > g}' "$f"
done
n=0; bad=0
for f in "$T"/sec-*; do
    case "$f" in *.sh) ;; *) head -1 "$f" | grep -q '^#!/usr/bin/bash' || grep -q '^ *\(sh_\)\?chk \|^echo \|^if ' "$f" || continue ;; esac
    n=$((n+1)); bash -n "$f" 2>/dev/null || { bad=$((bad+1)); echo "        syntax: $f"; }
done
[ "$n" -gt 0 ] && [ "$bad" -eq 0 ] && pass "bash -n on $n scripts" || fail "bash -n on $n scripts, $bad errors"

echo "--- 450: the updater reboots after a transaction, never otherwise ---"
section "cat > /usr/local/sbin/boot-update << 'BOOT_UPDATE_SH'" BOOT_UPDATE_SH ks.d/450-auto-updates.cfg \
    | sed -e 's|systemctl reboot|echo REBOOT-CALLED|' -e 's|sleep 5|true|' -e "s|^export PATH=.*|export PATH=$T/bin:/usr/bin:/bin|" > "$T/boot-update.sh"
# the mirror probe runs under timeout: the stub answers for it
stub timeout 'exit 0'
stub dnf5 'case "$*" in
  *check-upgrade*) exit "${STUB_CHECK:-100}" ;;
  *--downloadonly*) exit 0 ;;
  *upgrade*) exit "${STUB_UPGRADE:-0}" ;;
esac
exit 0'
out=$(STUB_CHECK=100 bash "$T/boot-update.sh" 2>&1)
case "$out" in *REBOOT-CALLED*) pass "reboot after an installed update" ;; *) fail "reboot after an installed update" ;; esac
out=$(STUB_CHECK=0 bash "$T/boot-update.sh" 2>&1)
case "$out" in *REBOOT-CALLED*) fail "no reboot when nothing is pending" ;; *) pass "no reboot when nothing is pending" ;; esac
out=$(STUB_CHECK=100 STUB_UPGRADE=1 bash "$T/boot-update.sh" 2>&1)
case "$out" in *REBOOT-CALLED*) fail "no reboot when the install failed" ;; *WARNING*) pass "no reboot when the install failed" ;; *) fail "no reboot when the install failed" ;; esac

echo "--- 990: the artifact listing ---"
mkdir -p "$T/root" "$T/verify.d"
printf '%s\n' 'sh_chk "a" "true"' > "$T/verify.d/100-a.sh"
touch "$T/root/ks-post-100-system.log"
section "cat > /usr/local/sbin/verify-install << 'VERIFY_EOF'" VERIFY_EOF ks.d/990-verify.cfg \
    | sed -e "s|/etc/verify.d|$T/verify.d|g" -e "s|/root/ks-post-|$T/root/ks-post-|g" -e "s|/var/log/anaconda|$T/anaconda|g" -e '/id -u/d' > "$T/vi.sh"
out=$(bash "$T/vi.sh" < /dev/null 2>&1)
case "$out" in *"ks-post-100-system.log"*) pass "one remaining artifact is listed" ;; *) fail "one remaining artifact is listed" ;; esac
rm -f "$T/root/ks-post-100-system.log"
out=$(bash "$T/vi.sh" < /dev/null 2>&1)
case "$out" in *"none, already shredded"*) pass "no artifact reads as none" ;; *) fail "no artifact reads as none" ;; esac

echo "--- 500: the MOK fragment reads mokutil's text, not its exit status ---"
touch "$T/sb-var"
section "cat > /etc/firstboot.d/500-uki-mok.sh << 'FRAG_EOF'" FRAG_EOF ks.d/500-uki-boot.cfg \
    | sed -e "s|/sys/firmware/efi/efivars/SecureBoot-[0-9a-f-]*|$T/sb-var|" > "$T/mok.sh"
stub mokutil 'echo "mokutil $*" >> "$STUB_LOG"
case "$1" in
  --test-key) if [ -n "${STUB_ENROLLED:-}" ]; then echo "key is already enrolled"; exit 1; fi; echo "key is not enrolled"; exit 0 ;;
  --list-new) exit 0 ;;
esac
exit 0'
export STUB_LOG="$T/calls"
: > "$STUB_LOG"
out=$(PATH="$T/bin:$PATH" STUB_ENROLLED=1 bash -euo pipefail -c ". $T/mok.sh" 2>&1)
case "$out" in *"UKI Secure Boot key: enrolled."*) pass "an enrolled key reads as enrolled" ;; *) fail "an enrolled key reads as enrolled" ;; esac
: > "$STUB_LOG"
out=$(PATH="$T/bin:$PATH" bash -euo pipefail -c ". $T/mok.sh" 2>&1)
grep -q '^mokutil --import' "$STUB_LOG" && pass "a key neither enrolled nor pending is imported" || fail "a key neither enrolled nor pending is imported"

echo "--- 510: the TPM fragment enrolls the root partition once ---"
rootmap=$(findmnt -no SOURCE / 2>/dev/null || true)
if [ ! -f optional/510-tpm-luks.cfg ]; then
    echo "        skipped: optional/510-tpm-luks.cfg is absent"
elif [ -z "$rootmap" ]; then
    echo "        skipped: no root mount to derive from"
else
    mkdir -p "$T/etc"
    section "cat > /etc/firstboot.d/510-tpm.sh << 'FRAG_EOF'" FRAG_EOF optional/510-tpm-luks.cfg \
        | sed -e "s|/etc/crypttab|$T/etc/crypttab|g" -e 's|\[ ! -e /dev/tpmrm0 \]|false|' > "$T/frag.sh"
    printf '%s\n' "${rootmap##*/} UUID=aaaa none discard" "luks-other UUID=bbbb none discard" > "$T/etc/crypttab"
    stub cryptsetup 'echo "cryptsetup $*" >> "$STUB_LOG"
if [ "$1" = luksDump ]; then [ -e "$STUB_DIR/enrolled" ] && echo systemd-tpm2; fi
exit 0'
    stub systemd-cryptenroll 'echo "systemd-cryptenroll $*" >> "$STUB_LOG"
[ -z "${STUB_FAIL:-}" ] || exit 1
touch "$STUB_DIR/enrolled"'
    stub kernel-install 'echo "kernel-install $*" >> "$STUB_LOG"'
    export STUB_DIR="$T"
    # sourced under the strict shell firstboot uses
    frag() { PATH="$T/bin:$PATH" bash -euo pipefail -c ". $T/frag.sh" < /dev/null >/dev/null 2>&1; }
    : > "$STUB_LOG"
    STUB_FAIL=1 frag
    [ "$(grep -c '^systemd-cryptenroll' "$STUB_LOG")" -eq 3 ] && ! grep -q tpm2-device "$T/etc/crypttab" && ! grep -q '^kernel-install' "$STUB_LOG" \
        && pass "three failed enrollments leave crypttab and the initramfs alone" || fail "three failed enrollments leave crypttab and the initramfs alone"
    : > "$STUB_LOG"
    frag
    grep -q "^systemd-cryptenroll .* /dev/" "$STUB_LOG" && pass "first run enrolls a partition under the root mapping" || fail "first run enrolls a partition under the root mapping"
    grep -q "^${rootmap##*/} .*tpm2-device=auto" "$T/etc/crypttab" && ! grep -q "^luks-other .*tpm2-device" "$T/etc/crypttab" \
        && pass "only the root mapping's crypttab line changes" || fail "only the root mapping's crypttab line changes"
    : > "$STUB_LOG"
    frag
    ! grep -q "^systemd-cryptenroll" "$STUB_LOG" && [ "$(grep -c tpm2-device "$T/etc/crypttab")" -eq 1 ] \
        && pass "a re-run enrolls nothing and keeps one crypttab edit" || fail "a re-run enrolls nothing and keeps one crypttab edit"
fi

echo "--- 205: the payload lands only where the new system has its directory ---"
mkdir -p "$T/sys/root" "$T/sys/var/lib" "$T/carry/root/keep" "$T/carry/var/lib/bluetooth/00:11:22:33:44:55/AA:BB:CC:DD:EE:FF"
chmod 750 "$T/sys/root"
printf 'x\n' > "$T/carry/root/keep/note"
printf 'x\n' > "$T/carry/var/lib/bluetooth/00:11:22:33:44:55/AA:BB:CC:DD:EE:FF/info"
printf '%s\n' /root /var/lib/bluetooth > "$T/carry.list"
section "%post --nochroot --erroronfail --interpreter=/usr/bin/bash" "%end" ks.d/205-carry-over.cfg \
    | sed -e "s|/tmp/carry|$T/carry|g" > "$T/carry.sh"
out=$(ANA_INSTALL_PATH="$T/sys" bash "$T/carry.sh" 2>&1)
[ -f "$T/sys/root/keep/note" ] && [ "$(stat -c %a "$T/sys/root")" = 750 ] \
    && pass "keep lands in /root and /root keeps its mode" || fail "keep lands in /root and /root keeps its mode"
[ ! -e "$T/sys/var/lib/bluetooth" ] && case "$out" in *"/var/lib/bluetooth absent"*) pass "bond keys stay out without the bluez directory" ;; *) fail "bond keys stay out without the bluez directory" ;; esac

echo "--- 615: the kill-switch guard ---"
if [ ! -f optional/615-wireguard-killswitch.cfg ]; then
    echo "        skipped: optional/615-wireguard-killswitch.cfg is absent"
else
    printf '%s\n' 'table inet killswitch {' > "$T/with605.conf"
    printf '%s\n' 'table inet filter {' > "$T/plain.conf"
    # the module's own guard statement, its continuation joined, pointed at a test ruleset
    guard() { bash -c "$(sed -n "/^! grep -q '^table inet killswitch {'/{N;s/\\\\\n/ /;p;q}" optional/615-wireguard-killswitch.cfg | sed "s|/etc/sysconfig/nftables.conf|$1|")"; }
    guard "$T/with605.conf" >/dev/null 2>&1 && fail "605's table is refused" || pass "605's table is refused"
    guard "$T/plain.conf" >/dev/null 2>&1 && pass "a plain ruleset passes" || fail "a plain ruleset passes"
fi

echo
echo "Result: $fails failed"
exit "$fails"
