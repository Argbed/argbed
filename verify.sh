#!/usr/bin/env bash
# Resolve the generated kickstart's package set against live Fedora repos
# in an empty installroot (weak deps off, same excludes as the kickstart).
# Only the repositories the installer resolves against are consulted:
# fedora, updates and the Fedora-hosted Cisco openh264 repository (the
# installed system records openh264 and mozilla-openh264 from it, inside
# the installer's own transaction). Third-party repositories configured
# on this host are not part of the install and stay out.
# Proves every hard dependency is satisfiable and shows the full closure
# WITHOUT installing anything. Run after any %packages change.
#
# Usage: ./verify.sh [releasever]   (default: the host's release)
set -euo pipefail
cd "$(dirname "$0")"

[ -f argbed.cfg ] || { echo "run ./build.sh first" >&2; exit 1; }

REL="${1:-$(rpm -E %fedora)}"
# Log lives here, not in /tmp: a fixed path in a world-writable
# directory can be pre-created (symlinked) by any local user.
LOG=./ks-verify.log
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

# Both lists come straight from the %packages blocks: one name per line,
# a leading "-" marks an exclude (710-sway's -xorg-x11-server-Xwayland),
# so a module's exclusion never needs repeating here. No parser package
# is needed on the build host.
PKGS=$(awk '/^%packages/{s=1;next} /^%end/{s=0}
            s && !/^[[:space:]]*(#|$)/ {sub(/[[:space:]]+#.*$/,""); if ($0 !~ /^-/) print}' argbed.cfg | sort -u)
EXCLUDES=$(awk '/^%packages/{s=1;next} /^%end/{s=0}
            s && /^-/ {sub(/[[:space:]]+#.*$/,""); print "--exclude=" substr($0,2)}' argbed.cfg | sort -u)

echo "Resolving $(echo "$PKGS" | wc -l) named packages against Fedora $REL..."
if dnf5 install --assumeno --installroot="$ROOT" --use-host-config \
        --disablerepo='*' --enablerepo=fedora --enablerepo=updates \
        --enablerepo=fedora-cisco-openh264 \
        --releasever="$REL" --setopt=install_weak_deps=False \
        $EXCLUDES \
        $PKGS 2>&1 | tee "$LOG" \
        | grep -v "Operation aborted" | tail -4; then
    :
fi
if grep -q "Transaction Summary" "$LOG"; then
    echo "OK: full dependency closure resolves (see $LOG)"
    echo "This was a dry run (--assumeno): dnf's 'Operation aborted by"
    echo "the user' in the log is expected; nothing was installed. The size"
    echo "shown covers ONLY this package list's closure: a real install also"
    echo "fetches anaconda's own additions (grub/shim bootloader step) and"
    echo "%post downloads (upgrade delta, third-party modules), so the actual"
    echo "download total will be larger."
else
    echo "FAILED: resolution error, see $LOG" >&2
    exit 1
fi
