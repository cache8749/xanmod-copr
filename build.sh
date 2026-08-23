#!/usr/bin/env bash
# build.sh - local equivalent of what the CI does.
#
#   ./build.sh              sync fedora/, assemble build/, build the SRPM
#   ./build.sh --binary     ... and build the RPMs locally instead (takes hours)
#   ./build.sh --no-sync    skip the Fedora sync and use fedora/ as it is
#
# Needs: git, jq, curl, xz, rpm-build. A local RPM build additionally needs the
# kernel build deps: dnf builddep build/kernel.spec
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT"

SYNC=1
MODE=-bs
for arg in "$@"; do
    case "$arg" in
        --binary)  MODE=-bb ;;
        --no-sync) SYNC=0 ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

eval "$(tools/xanmod-release.sh)"   # sets series, tag, version
echo "XanMod $tag (series $series)"

if [ "$SYNC" = 1 ]; then
    tools/sync-fedora.sh "$series"
fi

tools/assemble.sh "$version" "$tag"

mkdir -p build/rpmbuild/{BUILD,RPMS,SRPMS,SOURCES,SPECS,tmp}
rpmbuild "$MODE" \
    --define "debug_package %{nil}" \
    --define "_sourcedir $ROOT/build" \
    --define "_srcrpmdir $ROOT/build" \
    --define "_topdir $ROOT/build/rpmbuild" \
    --define "_tmppath $ROOT/build/rpmbuild/tmp" \
    build/kernel.spec
