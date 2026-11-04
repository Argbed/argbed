#!/usr/bin/env bash
# Assemble argbed.cfg from ks.d/*.cfg (lexical order) and validate it.
#
# Per-machine values (hostname, usernames, boot label, timezone, hardware
# firmware, resolvers) come from, in increasing precedence:
#   defaults below  <  build.conf  <  environment
# as in:  KS_HOSTNAME=laptop KS_ADMIN_USER=admin KS_DESKTOP_USER=me ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

_env_hostname="${KS_HOSTNAME-}"
_env_admin="${KS_ADMIN_USER-}"
_env_desktop="${KS_DESKTOP_USER-}"
_env_label="${KS_BOOT_LABEL-}"
_env_timezone="${KS_TIMEZONE-}"
_env_firmware="${KS_FIRMWARE-}"
_env_resolvers="${KS_RESOLVERS-}"

if [ -f build.conf ]; then
    . ./build.conf
fi

KS_HOSTNAME="${_env_hostname:-${KS_HOSTNAME:-MyFedoraBox}}"
KS_ADMIN_USER="${_env_admin:-${KS_ADMIN_USER:-mfadmin}}"
KS_DESKTOP_USER="${_env_desktop:-${KS_DESKTOP_USER:-mfuser}}"
# Firmware boot-entry label. Shown in NVRAM to anyone at the machine
# PRE-auth, so the default is generic, with nothing of this machine in it;
# a distinct label ("Fedora A") only tells one disk's entry from another's.
KS_BOOT_LABEL="${_env_label:-${KS_BOOT_LABEL:-Fedora Linux}}"
# System timezone (tzdata name). UTC by default: a zone names a region.
KS_TIMEZONE="${_env_timezone:-${KS_TIMEZONE:-UTC}}"
# Firmware packages for this machine, space-separated (build.conf.example
# lists them): the vendor subpackages linux-firmware only recommends, the
# CPU's microcode and the SOF audio DSP firmware.
KS_FIRMWARE="${_env_firmware:-${KS_FIRMWARE:-}}"
# Resolvers of the installed system and of the installer, IPv4, comma and
# space separated: the firewall pins port 53 to them.
KS_RESOLVERS="${_env_resolvers:-${KS_RESOLVERS:-1.1.1.1, 1.0.0.1}}"

[[ "$KS_HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] \
    || { echo "ERROR: invalid hostname '$KS_HOSTNAME'" >&2; exit 1; }
for u in "$KS_ADMIN_USER" "$KS_DESKTOP_USER"; do
    [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] \
        || { echo "ERROR: invalid username '$u'" >&2; exit 1; }
    [ "$u" != "root" ] || { echo "ERROR: 'root' is not allowed" >&2; exit 1; }
    # useradd makes a group of the same name and refuses an existing account
    # or group, after the wipe: the setup package's names are refused here,
    # and so are the build host's own system accounts and groups
    case " root bin daemon adm lp sync shutdown halt mail operator games ftp nobody sys tty disk mem kmem wheel cdrom man dialout floppy utmp tape kvm video lock audio users clock input render sgx " in
        *" $u "*) echo "ERROR: '$u' is a system account or group name" >&2; exit 1 ;;
    esac
    uid=$(getent passwd "$u" | cut -d: -f3 || true)
    if [ -n "$uid" ] && { [ "$uid" -lt 1000 ] || [ "$uid" -ge 65534 ]; }; then
        echo "ERROR: '$u' is a system account name (uid $uid on this host)" >&2; exit 1
    fi
    gid=$(getent group "$u" | cut -d: -f3 || true)
    if [ -n "$gid" ] && [ "$gid" -lt 1000 ]; then
        echo "ERROR: '$u' is a system group name (gid $gid on this host)" >&2; exit 1
    fi
done
[ "$KS_ADMIN_USER" != "$KS_DESKTOP_USER" ] \
    || { echo "ERROR: admin and desktop usernames must differ" >&2; exit 1; }
# Charset is deliberately strict: the label is spliced into shell strings
# in 500-uki-boot and into the signing certificate's subject (no quotes,
# $, &, /, \, =, +, comma allowed).
[[ "$KS_BOOT_LABEL" =~ ^[A-Za-z0-9][A-Za-z0-9\ ()._-]{0,39}$ ]] \
    || { echo "ERROR: invalid boot label '$KS_BOOT_LABEL' (allowed: letters digits space ()._- max 40)" >&2; exit 1; }
[[ "$KS_TIMEZONE" =~ ^[A-Za-z0-9/_+-]+$ ]] && [ -f "/usr/share/zoneinfo/$KS_TIMEZONE" ] \
    || { echo "ERROR: unknown timezone '$KS_TIMEZONE' (a name under /usr/share/zoneinfo)" >&2; exit 1; }
fw_lines=""
for p in $KS_FIRMWARE; do
    [[ "$p" =~ ^[a-z0-9][a-z0-9._+-]*$ ]] \
        || { echo "ERROR: invalid package name '$p' in KS_FIRMWARE" >&2; exit 1; }
    fw_lines="$fw_lines$p\\n"
done
fw_lines="${fw_lines%\\n}"
case " ${KS_FIRMWARE//[[:space:]]/ } " in
    *" microcode_ctl "*|*" amd-ucode-firmware "*) ;;
    *) echo "WARNING: KS_FIRMWARE names no microcode package: the CPU keeps its factory microcode" >&2 ;;
esac
oct='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
ip="$oct\\.$oct\\.$oct\\.$oct"
[[ "$KS_RESOLVERS" =~ ^$ip(,\ $ip)*$ ]] \
    || { echo "ERROR: invalid KS_RESOLVERS '$KS_RESOLVERS' (IPv4 addresses, comma and space separated)" >&2; exit 1; }

OUT=argbed.cfg
# the output appears only after the checks below
TMP=$(mktemp "$OUT.XXXXXX")
trap 'rm -f "$TMP"' EXIT

{
    echo "#version=Fedora"
    echo "# GENERATED FILE: edit the modules in ks.d/ and re-run ./build.sh"
    for mod in ks.d/*.cfg; do
        printf '\n# >>>>> %s\n' "$mod"
        cat "$mod"
        printf '\n# <<<<< %s\n' "$mod"
    done
} | sed -e "s/@KS_HOSTNAME@/$KS_HOSTNAME/g" \
        -e "s/@KS_ADMIN_USER@/$KS_ADMIN_USER/g" \
        -e "s/@KS_DESKTOP_USER@/$KS_DESKTOP_USER/g" \
        -e "s/@KS_BOOT_LABEL@/$KS_BOOT_LABEL/g" \
        -e "s|@KS_TIMEZONE@|$KS_TIMEZONE|g" \
        -e "s|@KS_FIRMWARE@|$fw_lines|g" \
        -e "s|@KS_RESOLVERS@|$KS_RESOLVERS|g" > "$TMP"

if grep -n -i '@KS_[A-Z0-9_]*@' "$TMP" >&2; then
    echo "ERROR: unreplaced @KS_...@ token (typo in a module?)" >&2
    exit 1
fi

if command -v ksvalidator >/dev/null 2>&1; then
    ksvalidator "$TMP"
    echo "OK: $OUT validated"
else
    echo "WARNING: ksvalidator not found, skipping validation." >&2
    echo "         Install it with: sudo dnf install pykickstart" >&2
fi
mv "$TMP" "$OUT"

echo "Identity: hostname=$KS_HOSTNAME admin=$KS_ADMIN_USER desktop=$KS_DESKTOP_USER"
echo "Boot entry label: $KS_BOOT_LABEL"
echo "Timezone: $KS_TIMEZONE"
echo "Hardware firmware: ${KS_FIRMWARE:-(none named)}"
echo "Resolvers: $KS_RESOLVERS"
echo "Wrote $OUT ($(wc -l < "$OUT") lines) from $(ls ks.d/*.cfg | wc -l) modules"
