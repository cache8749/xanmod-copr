#!/usr/bin/env bash
# assemble.sh - stage a buildable XanMod package in build/ from the pristine
# Fedora mirror in fedora/.
#
#   build/  = fedora/ verbatim
#           + kernel-*.config renamed to kernel-xanmod-*.config
#             (so Fedora's %{name}-* Source lines resolve without spec edits)
#           + our config overlay dropped in as kernel-local
#             (Fedora's own hook for custom config options)
#           + kernel.spec run through tools/spec-xanmod.py
#           + the kABI tarballs from Fedora's lookaside cache
#           + linux-<version>.tar.xz built from the XanMod tag
#
# build/ and cache/ are throwaway; nothing here is committed.
#
# Usage: tools/assemble.sh <version> <tag>    e.g. 7.2.0 7.2.0-xanmod1
set -euo pipefail

VERSION="${1:?Usage: $0 <version> <tag>}"
TAG="${2:?Usage: $0 <version> <tag>}"
PKG="${PKG_NAME:-kernel-xanmod}"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BUILD="$ROOT/build"
CACHE="$ROOT/cache"
LOOKASIDE="https://src.fedoraproject.org/repo/pkgs/rpms/kernel"

SERIES="${VERSION%.*}"

[ -f "$ROOT/fedora/kernel.spec" ] || {
    echo "ERROR: fedora/ is empty - run tools/sync-fedora.sh $SERIES first" >&2
    exit 1
}

# The whole point of the exercise: never build XanMod x.y against a Fedora
# package for a different kernel series.
FEDORA_SERIES=$(sed -n 's/^%define patchversion \([^ ]*\).*/\1/p' "$ROOT/fedora/kernel.spec" | head -n 1)
if [ "$FEDORA_SERIES" != "$SERIES" ]; then
    echo "ERROR: fedora/ is kernel $FEDORA_SERIES but XanMod is $SERIES - refusing to build" >&2
    exit 1
fi

echo "=== Staging pristine Fedora files ==="
rm -rf "$BUILD"
mkdir -p "$BUILD" "$CACHE"
tar -C "$ROOT/fedora" --exclude=.git --exclude=.gitignore -cf - . | tar -C "$BUILD" -xf -

echo "=== Renaming configs for package name $PKG ==="
for f in "$BUILD"/kernel-*.config; do
    base=$(basename "$f")
    mv "$f" "$BUILD/$PKG-${base#kernel-}"
done
mv "$BUILD/kernel.changelog" "$BUILD/$PKG.changelog"
echo "  $(ls "$BUILD/$PKG"-*.config | wc -l) config files renamed to $PKG-*"

echo "=== Rewriting the spec ==="
python3 "$ROOT/tools/spec-xanmod.py" "$BUILD/kernel.spec" \
    --version "$VERSION" --package-name "$PKG"

echo "=== Fetching Fedora lookaside sources ==="
# Everything in fedora/sources except the kernel tarball, which we build ourselves.
while read -r _ file _ hash; do
    file=${file#(}; file=${file%)}
    case "$file" in
        linux-*.tar.xz) continue ;;
    esac
    if [ ! -f "$CACHE/$file" ]; then
        echo "  downloading $file"
        curl -fsS -o "$CACHE/$file.part" "$LOOKASIDE/$file/sha512/$hash/$file"
        mv "$CACHE/$file.part" "$CACHE/$file"
    fi
    echo "$hash  $CACHE/$file" | sha512sum --quiet -c - || {
        echo "ERROR: checksum mismatch for $file" >&2
        rm -f "$CACHE/$file"
        exit 1
    }
    cp -l "$CACHE/$file" "$BUILD/$file" 2>/dev/null || cp "$CACHE/$file" "$BUILD/$file"
    echo "  $file ok"
done < "$ROOT/fedora/sources"
rm -f "$BUILD/sources"

echo "=== XanMod source tarball ==="
"$ROOT/tools/get-source.sh" "$TAG" "$VERSION" "$CACHE"
cp -l "$CACHE/linux-$VERSION.tar.xz" "$BUILD/" 2>/dev/null \
    || cp "$CACHE/linux-$VERSION.tar.xz" "$BUILD/"

echo "=== Config: XanMod's own x86_64 config ==="
# XanMod ships the config it builds with in-tree, so take it from the release being
# built instead of keeping a copy here that goes stale. Only the x86_64 base config
# is replaced: the rt variant keeps Fedora's config (it needs PREEMPT_RT, which
# XanMod's config does not set) and other arches are not built in copr anyway.
IN_TREE="linux-$VERSION/CONFIGS/x86_64/config"
if ! tar -xf "$BUILD/linux-$VERSION.tar.xz" -C "$BUILD" "$IN_TREE" 2>/dev/null; then
    echo "ERROR: $IN_TREE is not in the XanMod tarball - did XanMod move its configs?" >&2
    exit 1
fi
python3 - "$BUILD/$IN_TREE" "$BUILD/$PKG-x86_64-fedora.config" <<'PY'
import re, sys

xanmod_path, fedora_path = sys.argv[1], sys.argv[2]
SET = re.compile(r"^(CONFIG_\w+)=")
NOTSET = re.compile(r"^#\s+(CONFIG_\w+)\s+is not set$")

def symbol(line):
    m = SET.match(line) or NOTSET.match(line)
    return m.group(1) if m else None

fedora = {}
for line in open(fedora_path):
    s = symbol(line.rstrip("\n"))
    if s:
        fedora[s] = line.rstrip("\n")

# Symbols Fedora's *packaging* owns. Everything else - including the x86-64-v3 ISA
# level and every tuning choice - is taken from XanMod verbatim.
#   LOCALVERSION: the spec sets the release string through EXTRAVERSION and installs
#     modules with KERNELRELEASE=, so a suffix here makes the booted kernel look for
#     a /lib/modules directory that was never packaged.
#   LSM/DEFAULT_SECURITY: XanMod leaves selinux out of the default LSM list, which
#     would silently boot Fedora with SELinux inactive.
#   MODULE_COMPRESS: the spec compresses modules itself (zipmodules=1) and %files
#     expects to find *.ko to compress.
FROM_FEDORA = ("CONFIG_LSM", "CONFIG_DEFAULT_SECURITY_SELINUX", "CONFIG_DEFAULT_SECURITY_DAC")
FORCE = {
    "CONFIG_LOCALVERSION": 'CONFIG_LOCALVERSION=""',
    "CONFIG_MODULE_COMPRESS": "# CONFIG_MODULE_COMPRESS is not set",
}
# If XanMod ever drops these, the spec breaks in ways that are hard to read.
# Signing has to keep working with what the Fedora mirror provides: the build
# generates certs/signing_key.pem from x509.genkey.fedora, mod-sign.sh signs every
# module with it, and %prep seds SYSTEM_TRUSTED_KEYS/EFI_SBAT_FILE (so they have to
# be the empty strings it looks for) to compile in Fedora's IMA CA and SBAT data.
REQUIRE = {
    "CONFIG_MODULE_SIG": "y", "CONFIG_MODULE_SIG_ALL": "y",
    "CONFIG_MODULE_SIG_KEY": '"certs/signing_key.pem"',
    "CONFIG_SYSTEM_TRUSTED_KEYRING": "y",
    "CONFIG_SYSTEM_TRUSTED_KEYS": '""', "CONFIG_EFI_SBAT_FILE": '""',
    "CONFIG_DEBUG_INFO_BTF": "y",
}

out, seen, changes = [], set(), []
for line in open(xanmod_path):
    line = line.rstrip("\n")
    s = symbol(line)
    if s:
        seen.add(s)
        if s in REQUIRE:
            want, got = REQUIRE[s], line.split("=", 1)[1] if "=" in line else "(not set)"
            if got != want:
                sys.exit(f"ERROR: XanMod's config has {s}={got}, but Fedora's spec needs {want}")
        if s in FORCE and line != FORCE[s]:
            changes.append(f"{line}  ->  {FORCE[s]}")
            line = FORCE[s]
        elif s in FROM_FEDORA and s in fedora and line != fedora[s]:
            changes.append(f"{line}  ->  {fedora[s]}")
            line = fedora[s]
    out.append(line)

for s in FROM_FEDORA:
    if s not in seen and s in fedora:
        changes.append(f"(absent)  ->  {fedora[s]}")
        out.append(fedora[s])
for s, v in REQUIRE.items():
    if s not in seen:
        sys.exit(f"ERROR: XanMod's config does not mention {s}, which Fedora's spec needs set to {v}")

open(fedora_path, "w").write("\n".join(out) + "\n")
print(f"  {len(seen)} symbols from XanMod -> {fedora_path.split('/')[-1]}")
print("  kept from Fedora for packaging reasons:")
for c in changes:
    print(f"    {c}")
PY
rm -rf "$BUILD/linux-$VERSION"

if command -v rpmspec >/dev/null; then
    echo "=== Resulting package ==="
    rpmspec -q --srpm --define "dist %{nil}" \
        --qf '%{name}-%{version}-%{release}\n' "$BUILD/kernel.spec"
fi

echo "build/ ready ($(du -sh "$BUILD" | cut -f1))"
