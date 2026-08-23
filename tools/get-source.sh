#!/usr/bin/env bash
# get-source.sh - build a kernel.org-style source tarball from a XanMod git tag.
#
# Fedora's kernel.spec expects Source0 to be linux-%{tarfile_release}.tar.xz with
# a linux-%{tarfile_release}/ top-level directory. We produce exactly that from
# the tag itself, so Source0 and the %prep/%setup lines stay pristine.
#
# Usage: tools/get-source.sh <tag> <version> [outdir]
#   tag     xanmod git tag, e.g. 7.2.0-xanmod1
#   version kernel version the spec is built for, e.g. 7.2.0
#   outdir  where the tarball is written (default: cache/)
set -euo pipefail

TAG="${1:?Usage: $0 <tag> <version> [outdir]}"
VERSION="${2:?Usage: $0 <tag> <version> [outdir]}"
OUTDIR="${3:-cache}"
REPO="${XANMOD_REPO:-https://gitlab.com/xanmod/linux.git}"
XZ_LEVEL="${XZ_LEVEL:--3}"

OUT="$OUTDIR/linux-$VERSION.tar.xz"
mkdir -p "$OUTDIR"

if [ -f "$OUT" ]; then
    echo "$OUT already present, keeping it"
    exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/xanmod-src.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

echo "Cloning $REPO at tag $TAG (shallow) ..."
git clone --quiet --depth 1 --single-branch --branch "$TAG" "$REPO" "$WORK/linux"

# Make sure we really got the tag and not a same-named branch.
GOT=$(git -C "$WORK/linux" describe --tags --exact-match HEAD)
if [ "$GOT" != "$TAG" ]; then
    echo "ERROR: checkout is '$GOT', expected tag '$TAG'" >&2
    exit 1
fi
echo "Tag $TAG resolves to commit $(git -C "$WORK/linux" rev-parse HEAD)"

# Sanity check that the tree really is the version the spec will claim.
MK_VERSION=$(awk -F' = ' '
    /^VERSION =/      {v=$2}
    /^PATCHLEVEL =/   {p=$2}
    /^SUBLEVEL =/     {s=$2}
    END {print v "." p "." s}' "$WORK/linux/Makefile")
if [ "$MK_VERSION" != "$VERSION" ]; then
    echo "ERROR: tree Makefile says $MK_VERSION, spec will say $VERSION" >&2
    exit 1
fi

echo "Creating $OUT (top-level dir linux-$VERSION/) ..."
git -C "$WORK/linux" archive --format=tar --prefix="linux-$VERSION/" HEAD \
    | xz -T0 "$XZ_LEVEL" > "$OUT.part"
mv "$OUT.part" "$OUT"
ls -lh "$OUT"
