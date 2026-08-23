#!/usr/bin/env bash
# xanmod-release.sh - resolve the XanMod series and its newest release tag.
#
# The series is XanMod's default branch (e.g. "7.2"); that is what decides which
# Fedora dist-git branch we have to sync against.
#
# Usage: tools/xanmod-release.sh [series]
# Outputs KEY=value lines on stdout, and the same into $GITHUB_OUTPUT when set.
set -euo pipefail

API="https://gitlab.com/api/v4/projects/xanmod%2Flinux"

SERIES="${1:-}"
if [ -z "$SERIES" ]; then
    SERIES=$(curl -fsS "$API" | jq -r '.default_branch')
fi

if ! [[ "$SERIES" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: '$SERIES' does not look like a XanMod series (expected e.g. 7.2)" >&2
    exit 1
fi

# Newest X.Y.Z-xanmodN tag in the series. Plain "-xanmodN" only: the "-rt-xanmodN"
# tags are a separate flavour with their own release cadence.
TAG=$(curl -fsS "$API/repository/tags?per_page=100&search=$SERIES" \
    | jq -r '.[].name' \
    | grep -E "^${SERIES//./\\.}\.[0-9]+-xanmod[0-9]+$" \
    | sort -V | tail -n 1)

if [ -z "$TAG" ]; then
    echo "ERROR: no ${SERIES}.x-xanmodN tag found" >&2
    exit 1
fi

VERSION="${TAG%-xanmod*}"

{
    echo "series=$SERIES"
    echo "tag=$TAG"
    echo "version=$VERSION"
} | tee -a "${GITHUB_OUTPUT:-/dev/null}"
