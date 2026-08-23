# XanMod for Fedora

Builds the [XanMod](https://xanmod.org) kernel as `kernel-xanmod` using Fedora's own
kernel packaging, kept in sync with
[Fedora's kernel dist-git](https://src.fedoraproject.org/rpms/kernel).

The rule that shapes everything here: **nothing in `fedora/` is ever edited.**
It is a verbatim mirror of a Fedora dist-git branch. Every XanMod-specific change
is a few lines of generated diff produced at build time by `tools/spec-xanmod.py`,
so a Fedora rebase is a re-sync rather than a merge conflict.

## How a build happens

1. `tools/xanmod-release.sh` reads XanMod's default branch (the *series*, e.g. `7.2`)
   and the newest `X.Y.Z-xanmodN` tag in it.
2. `tools/sync-fedora.sh <series>` picks the highest-numbered `fNN` dist-git branch
   whose `kernel.spec` is for the same series and mirrors it into `fedora/`.
   `rawhide`/`main` (always a series ahead) and `stabilization` are never used.
   If no released branch ships that series yet, **the build is skipped** rather than
   run against a mismatched spec.
3. `tools/assemble.sh <version> <tag>` stages `build/` from `fedora/`:
   - `kernel-*.config` → `kernel-xanmod-*.config` and `kernel.changelog` →
     `kernel-xanmod.changelog`, so Fedora's `%{name}-*` Source lines resolve with no
     spec edits at all;
   - `kernel.spec` is rewritten by `tools/spec-xanmod.py` (see below);
   - the two kABI tarballs are fetched from Fedora's lookaside cache and checksummed
     against `fedora/sources`;
   - `tools/get-source.sh` shallow-clones the XanMod tag and `git archive`s it into
     `linux-<version>.tar.xz` with a `linux-<version>/` top-level directory — exactly
     the layout Fedora's `Source0` and `%setup` already expect;
   - the x86_64 config is taken from `CONFIGS/x86_64/config` inside that release (see
     below), so no config is stored in this repo.
4. `rpmbuild -bs` → `copr-cli build`.

`build/` and `cache/` are scratch and gitignored. `fedora-sync.json` records what
`fedora/` mirrors; `build-state.json` records what was last submitted to copr.

## What the spec transform actually changes

`tools/spec-xanmod.py` makes six edits, and **fails the build** if any of them stops
matching — a Fedora refactor produces a loud error instead of a subtly wrong kernel.

| Change | Why |
|---|---|
| prepend `%define _with_vanilla 1` | `nopatches=1`, so Fedora's `patch-<series>-redhat.patch` is skipped (it does not apply to the XanMod tree) and, as a side effect, `with_configchecks=0` |
| prepend `%define _without_debug 1` / `_without_debuginfo 1` | no debug kernel, no debuginfo packages |
| prepend `%define _with_realtime 1` | Fedora defaults RT off and only builds it on request; this gives `kernel-xanmod-rt` |
| prepend `%define buildid .xanmod1` | release becomes e.g. `61.xanmod1.fc45` |
| `%global package_name kernel-xanmod` | so this does not collide with Fedora's own `kernel` |
| `specrpmversion`, `specversion`, `tarfile_release`, `patchversion`, `kversion`, `patchlevel` | the XanMod version |

Deliberately left alone: `Source0`/`%setup` (the tarball is built to match),
`kabiversion` (it names the lookaside kABI tarballs, so it tracks Fedora, not
XanMod), and `pkgrelease`/`specrelease` — keeping Fedora's release number is what
gives users an upgrade path when Fedora rebases the same kernel version.

## When does it rebuild?

Daily at 06:00 UTC, and it submits a build when any of these changed since
`build-state.json`: the XanMod tag, the Fedora branch, or Fedora's `pkgrelease`.
Run the workflow manually with **force** to rebuild regardless.

## Config

XanMod ships the config it builds with in-tree at `CONFIGS/x86_64/config`, so
`tools/assemble.sh` takes it straight out of the release being built and installs it
as the x86_64 config. Nothing is stored in this repo and nothing goes stale — when
XanMod changes its tuning, the next build follows. That config is XanMod's
**x86-64-v3** build (`CONFIG_LOCALVERSION="-x64v3"`), so the resulting kernel needs a
v3-capable CPU; that is intentional.

Four symbols are taken from Fedora's config instead, because they are packaging
rather than tuning, and every one of them is printed during assembly:

| Symbol | Why Fedora wins |
|---|---|
| `CONFIG_LOCALVERSION` | the spec sets the release string via `EXTRAVERSION` and installs modules with `KERNELRELEASE=`; a suffix here makes the booted kernel look for a `/lib/modules` directory that was never packaged |
| `CONFIG_LSM`, `CONFIG_DEFAULT_SECURITY_SELINUX`, `CONFIG_DEFAULT_SECURITY_DAC` | XanMod leaves `selinux` out of the default LSM list, which would boot Fedora with SELinux inactive |

`CONFIG_MODULE_COMPRESS` is additionally forced off (the spec compresses modules
itself and `%files` expects to find `*.ko`), and assembly aborts if XanMod's config
stops satisfying what the spec relies on: `MODULE_SIG`, `MODULE_SIG_ALL`,
`MODULE_SIG_KEY="certs/signing_key.pem"`, `SYSTEM_TRUSTED_KEYRING`, an empty
`SYSTEM_TRUSTED_KEYS`, an empty `EFI_SBAT_FILE`, and `DEBUG_INFO_BTF`.

The rt variant keeps Fedora's config — it needs `PREEMPT_RT`, which XanMod's config
does not set (XanMod ships separate `-rt-xanmodN` tags for that).

## Signing

Signing is Fedora's, unmodified, using the keys that come with the mirror:

- **Modules are really signed.** The build generates `certs/signing_key.pem` from
  `x509.genkey.fedora`, `mod-sign.sh` signs every `.ko` with it, and the matching
  public key is compiled into the same kernel — so modules load even under lockdown.
  The certificate is shipped in `/usr/share/doc/kernel-keys/<kver>/`.
- **`CONFIG_SYSTEM_TRUSTED_KEYS`** is rewritten by `%prep` to `certs/rhel.pem`, which
  gets Fedora's IMA CA certificate (`fedoraimaca.x509`) — hence the assertion that
  XanMod leaves that symbol empty.
- **The kernel image is pesigned, but not with a key any firmware trusts.**
  `redhatsecureboot501.cer`/`redhatsecurebootca5.cer` in the mirror are only public
  certificates; the private keys live in Fedora's signing infrastructure. Outside it,
  pesign self-signs with a locally generated key, so Secure Boot machines still need
  the key enrolled (MOK) or Secure Boot off. Same as before this rework.

## Local use

```sh
./build.sh              # sync, assemble, build the SRPM
./build.sh --no-sync    # use fedora/ as-is
./build.sh --binary     # build RPMs locally (hours; needs dnf builddep build/kernel.spec)
```

## Maintenance notes

- A Fedora spec refactor that renames what the transform keys on fails in
  `tools/spec-xanmod.py` with the exact pattern that no longer matches.
- `tools/assemble.sh` refuses to build if `fedora/` is for a different kernel series
  than the XanMod version being built.
- `tools/get-source.sh` verifies the clone really is the requested tag and that the
  tree's `Makefile` version matches what the spec will claim.
- The XanMod tarball is rebuilt from scratch on every run (~4 min). If that ever
  matters, cache `cache/linux-<version>.tar.xz` keyed on the tag.
