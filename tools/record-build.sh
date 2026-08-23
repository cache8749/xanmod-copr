#!/usr/bin/env bash
# record-build.sh - remember what was last submitted to copr.
#
# build-state.json is the only thing that stops the daily job from rebuilding the
# same NVR over and over. It is written after a successful copr submit, so a
# failed run is retried on the next schedule.
#
# Usage: tools/record-build.sh <tag> <version> <srpm>
set -euo pipefail

TAG="${1:?Usage: $0 <tag> <version> <srpm>}"
VERSION="${2:?Usage: $0 <tag> <version> <srpm>}"
SRPM="${3:?Usage: $0 <tag> <version> <srpm>}"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

jq -n \
    --arg tag "$TAG" \
    --arg version "$VERSION" \
    --arg srpm "$(basename "$SRPM")" \
    --arg submitted "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --slurpfile fedora "$ROOT/fedora-sync.json" \
    '{xanmod_tag: $tag, xanmod_version: $version, srpm: $srpm, submitted: $submitted,
      fedora_branch: $fedora[0].branch, fedora_commit: $fedora[0].commit,
      fedora_pkgrelease: $fedora[0].pkgrelease}' > "$ROOT/build-state.json"

cat "$ROOT/build-state.json"
