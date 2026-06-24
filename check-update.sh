#!/bin/bash
# check-update.sh - Check for new xanmod kernel releases and update the spec
# Usage: ./check-update.sh <branch_prefix>
#   branch_prefix: e.g. "7.0" for MAIN, "7.1" for EDGE
set -euo pipefail

SPEC_FILE="kernel.spec"
BRANCH_PREFIX="${1:?Usage: $0 <branch_prefix> (e.g. 7.0 or 7.1)}"

# Get latest xanmod tag matching the given branch prefix
LATEST_TAG=$(curl -s 'https://gitlab.com/api/v4/projects/xanmod%2Flinux/repository/tags?per_page=50' \
    | jq -r '.[].name' \
    | grep -E "^${BRANCH_PREFIX}\.[0-9]+-xanmod1$" \
    | head -n 1)

if [ -z "$LATEST_TAG" ]; then
    echo "ERROR: Could not find any tag matching ${BRANCH_PREFIX}.x-xanmod1"
    exit 1
fi

# Parse version from tag (e.g. "7.0.13-xanmod1" -> "7.0.13")
LATEST_VERSION="${LATEST_TAG%-xanmod1}"
MAJOR_MINOR="${LATEST_VERSION%.*}"
KVERSION="${MAJOR_MINOR%%.*}"
PATCHLEVEL="${MAJOR_MINOR#*.}"

echo "Branch prefix: $BRANCH_PREFIX"
echo "Latest xanmod tag: $LATEST_TAG"
echo "Latest version: $LATEST_VERSION"

# Get current version from spec
CURRENT_VERSION=$(grep '^%define specrpmversion' "$SPEC_FILE" | awk '{print $3}')
echo "Current spec version: $CURRENT_VERSION"

if [ "$LATEST_VERSION" = "$CURRENT_VERSION" ]; then
    echo "Already up to date."
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        echo "updated=false" >> "$GITHUB_OUTPUT"
    fi
    exit 0
fi

echo "New version available: $CURRENT_VERSION -> $LATEST_VERSION"

# Update version fields in the spec file
sed -i "s/^%define specrpmversion .*/%define specrpmversion $LATEST_VERSION/" "$SPEC_FILE"
sed -i "s/^%define specversion .*/%define specversion $LATEST_VERSION/" "$SPEC_FILE"
sed -i "s/^%define patchversion .*/%define patchversion $MAJOR_MINOR/" "$SPEC_FILE"
sed -i "s/^%define kversion .*/%define kversion $KVERSION/" "$SPEC_FILE"
sed -i "s/^%define tarfile_release .*/%define tarfile_release $LATEST_VERSION/" "$SPEC_FILE"
sed -i "s/^%define patchlevel .*/%define patchlevel $PATCHLEVEL/" "$SPEC_FILE"
sed -i "s/^%define kabiversion .*/%define kabiversion $LATEST_VERSION/" "$SPEC_FILE"

echo "Spec file updated to $LATEST_VERSION"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "updated=true" >> "$GITHUB_OUTPUT"
    echo "version=$LATEST_VERSION" >> "$GITHUB_OUTPUT"
    echo "tag=$LATEST_TAG" >> "$GITHUB_OUTPUT"
fi
