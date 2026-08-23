#!/usr/bin/env bash
# sync-fedora.sh - mirror the matching Fedora kernel dist-git branch into fedora/.
#
# Picks the highest-numbered fNN branch of https://src.fedoraproject.org/rpms/kernel
# whose kernel.spec %patchversion equals the XanMod series, and copies that branch
# verbatim into fedora/. rawhide/main (always a series ahead) and stabilization
# (a staging branch) are deliberately never used.
#
# If no branch matches, nothing is touched and matched=false is reported, so the
# caller can skip the build instead of building against a mismatched spec.
#
# Usage: tools/sync-fedora.sh <series>    e.g. 7.2
set -euo pipefail

SERIES="${1:?Usage: $0 <series> (e.g. 7.2)}"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DISTGIT="https://src.fedoraproject.org/rpms/kernel.git"
BRANCH_API="https://src.fedoraproject.org/api/0/rpms/kernel/git/branches"
RAW="https://src.fedoraproject.org/rpms/kernel/raw"
# What fedora/ currently mirrors. build-state.json (what was last built) is a
# separate file on purpose: this one is rewritten before every build decision.
SYNCFILE="$ROOT/fedora-sync.json"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fedora-sync.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

emit() { echo "$1" | tee -a "${GITHUB_OUTPUT:-/dev/null}"; }

spec_define() { # spec_define <file> <name>
    sed -n "s/^%define $2 \([^ ]*\).*/\1/p" "$1" | head -n 1
}

# Released Fedora branches, newest first.
BRANCHES=$(curl -fsS "$BRANCH_API" | jq -r '.branches[]' \
    | grep -E '^f[0-9]+$' | sort -t f -k2 -nr)

echo "XanMod series: $SERIES"
echo "Candidate Fedora branches: $(echo "$BRANCHES" | tr '\n' ' ')"

older_than() { # older_than <a> <b> -> true if version a sorts below b
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" ]
}

# Walk newest first and stop as soon as a branch is older than the series: Fedora
# branch numbers and kernel versions move in lockstep, so nothing older can match.
# A failed fetch is fatal on purpose - silently skipping a branch here would mean
# concluding "no match" and skipping a build that should have happened.
MATCH=""
for b in $BRANCHES; do
    if ! curl -fsS --retry 3 --retry-delay 2 --retry-all-errors \
            -o "$WORK/spec" "$RAW/$b/f/kernel.spec"; then
        echo "ERROR: could not fetch kernel.spec from Fedora branch $b" >&2
        exit 1
    fi
    pv=$(spec_define "$WORK/spec" patchversion)
    ver=$(spec_define "$WORK/spec" specrpmversion)
    echo "  $b: kernel ${ver:-?} (patchversion ${pv:-?})"
    if [ "$pv" = "$SERIES" ]; then
        MATCH="$b"
        break
    fi
    if [ -n "$pv" ] && older_than "$pv" "$SERIES"; then
        echo "  (stopping: $b is already older than $SERIES)"
        break
    fi
done

if [ -z "$MATCH" ]; then
    echo "::warning title=No matching Fedora branch::No released Fedora branch ships kernel $SERIES yet (rawhide excluded by design); leaving fedora/ untouched"
    emit "matched=false"
    exit 0
fi

echo "Syncing fedora/ from dist-git branch $MATCH"
git clone --quiet --depth 1 --single-branch --branch "$MATCH" "$DISTGIT" "$WORK/distgit"
COMMIT=$(git -C "$WORK/distgit" rev-parse HEAD)
SUBJECT=$(git -C "$WORK/distgit" log -1 --format=%s)

rm -rf "$ROOT/fedora"
mkdir -p "$ROOT/fedora"
tar -C "$WORK/distgit" --exclude=.git -cf - . | tar -C "$ROOT/fedora" -xf -

SPEC="$ROOT/fedora/kernel.spec"
FEDORA_VERSION=$(spec_define "$SPEC" specrpmversion)
FEDORA_PATCHVERSION=$(spec_define "$SPEC" patchversion)
FEDORA_PKGRELEASE=$(spec_define "$SPEC" pkgrelease)
FEDORA_KABIVERSION=$(spec_define "$SPEC" kabiversion)

[ -n "$FEDORA_VERSION" ] && [ -n "$FEDORA_PKGRELEASE" ] || {
    echo "ERROR: could not read version defines out of the synced spec" >&2
    exit 1
}

jq -n \
    --arg branch "$MATCH" \
    --arg commit "$COMMIT" \
    --arg nvr "$SUBJECT" \
    --arg version "$FEDORA_VERSION" \
    --arg patchversion "$FEDORA_PATCHVERSION" \
    --arg pkgrelease "$FEDORA_PKGRELEASE" \
    --arg kabiversion "$FEDORA_KABIVERSION" \
    '{branch: $branch, commit: $commit, nvr: $nvr, version: $version,
      patchversion: $patchversion, pkgrelease: $pkgrelease, kabiversion: $kabiversion}' \
    > "$SYNCFILE"

echo "Synced $MATCH @ ${COMMIT:0:12} ($SUBJECT)"
emit "matched=true"
emit "branch=$MATCH"
emit "commit=$COMMIT"
emit "fedora_version=$FEDORA_VERSION"
emit "fedora_pkgrelease=$FEDORA_PKGRELEASE"
