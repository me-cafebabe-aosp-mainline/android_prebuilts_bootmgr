#!/bin/bash
#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#
# Rebuilds the GRUB prebuilts in this directory from a GRUB source tree.
#
# The tools are built for the (x86_64) build host. The modules and images are
# for the platform: arm64-efi is cross compiled with aarch64-linux-gnu-gcc and
# the i386 ones are built with the host compiler.
#
# The build is done from a clean worktree of a committed revision, so
# uncommitted changes and the state of an in-tree build do not matter.
#

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

HOST_TAG=linux-x86
PREFIX_BASE=//prebuilts/bootmgr/grub

# name -> arguments of configure
declare -A CONFIGURE_ARGS=(
    [x86_64-efi]="--with-platform=efi"
    [i386-efi]="--target=i386 --with-platform=efi"
    [i386-pc]="--target=i386 --with-platform=pc"
    [arm64-efi]="--target=aarch64-linux-gnu --with-platform=efi"
)
ALL_PLATFORMS="x86_64-efi i386-efi i386-pc arm64-efi"

APT_PACKAGES="autoconf autopoint bison build-essential flex gawk gettext git libfreetype-dev pkg-config python3 unifont"
APT_PACKAGES_ARM64="gcc-aarch64-linux-gnu"

usage() {
    cat <<EOF
Usage: $0 --src GRUB_SOURCE_DIR [options]

Options:
  -s, --src DIR         GRUB git repository (or set GRUB_SRC)
  -r, --rev REV         revision to build (default: HEAD)
  -p, --platforms LIST  space separated, from: $ALL_PLATFORMS
                        (default: all of them)
  -o, --out DIR         directory that has $HOST_TAG/ in it
                        (default: the directory of this script). CHANGES_grub
                        is written to the parent directory.
  -w, --work DIR        working directory (default: a new temporary directory)
  -j, --jobs N          make jobs in total (default: number of CPUs)
  -u, --upstream REF    upstream ref in the GRUB repository, to find the local
                        patches for CHANGES_grub (default: origin/master)
      --no-bootstrap    do not run ./bootstrap (the revision must have its
                        generated files, or GNULIB_SRCDIR must be enough)
      --no-changes      do not update CHANGES_grub
      --commit          commit the result, one commit per platform
      --trailer TEXT    add a trailer to the commits, can be repeated
                        (for example "Assisted-by: LLM")
      --keep-work       do not delete the working directory
  -h, --help            show this

GNULIB_SRCDIR is passed on to ./bootstrap (a local gnulib checkout, to avoid
cloning it).

Needed on a Debian based build host:
  sudo apt install $APT_PACKAGES
  and for arm64-efi: $APT_PACKAGES_ARM64
EOF
}

die() {
    echo "$(basename "$0"): $*" >&2
    exit 1
}

log() {
    echo "==> $*"
}

SRC=${GRUB_SRC:-}
REV=HEAD
PLATFORMS=$ALL_PLATFORMS
OUT=$SCRIPT_DIR
WORK=
JOBS=$(nproc)
UPSTREAM=origin/master
DO_BOOTSTRAP=1
DO_CHANGES=1
DO_COMMIT=0
KEEP_WORK=0
TRAILERS=()

while [ $# -gt 0 ]; do
    case "$1" in
        -s|--src) SRC=$2; shift 2 ;;
        -r|--rev) REV=$2; shift 2 ;;
        -p|--platforms) PLATFORMS=$2; shift 2 ;;
        -o|--out) OUT=$2; shift 2 ;;
        -w|--work) WORK=$2; shift 2 ;;
        -j|--jobs) JOBS=$2; shift 2 ;;
        -u|--upstream) UPSTREAM=$2; shift 2 ;;
        --no-bootstrap) DO_BOOTSTRAP=0; shift ;;
        --no-changes) DO_CHANGES=0; shift ;;
        --commit) DO_COMMIT=1; shift ;;
        --trailer) TRAILERS+=("$2"); shift 2 ;;
        --keep-work) KEEP_WORK=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

# Checks

[ -n "$SRC" ] || { usage >&2; die "--src is required"; }
git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1 || die "$SRC is not a git repository"
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] ||
    die "the $HOST_TAG prebuilts must be built on an x86_64 Linux host"
[ "$JOBS" -ge 1 ] 2>/dev/null || die "invalid number of jobs: $JOBS"

for platform in $PLATFORMS; do
    [ -n "${CONFIGURE_ARGS[$platform]:-}" ] || die "unknown platform: $platform"
done

missing=()
for tool in git make gcc python3 autoconf automake bison flex gawk msgfmt; do
    command -v "$tool" >/dev/null || missing+=("$tool")
done
case " $PLATFORMS " in
    *" arm64-efi "*)
        command -v aarch64-linux-gnu-gcc >/dev/null || missing+=(aarch64-linux-gnu-gcc)
        ;;
esac
[ ${#missing[@]} -eq 0 ] || die "missing tools: ${missing[*]}
Install the build dependencies, see --help"
[ -e /usr/share/fonts/X11/misc/unifont.pcf.gz ] || [ -e /usr/share/unifont/unifont.pcf.gz ] ||
    echo "Warning: unifont was not found, configure will complain if it is needed" >&2

if [ "$DO_COMMIT" = 1 ]; then
    git -C "$OUT" rev-parse --git-dir >/dev/null 2>&1 || die "$OUT is not in a git repository"
fi

HEAD_HASH=$(git -C "$SRC" rev-parse --verify "$REV^{commit}") || die "unknown revision: $REV"
UPSTREAM_BASE=
if git -C "$SRC" rev-parse --verify -q "$UPSTREAM^{commit}" >/dev/null; then
    UPSTREAM_BASE=$(git -C "$SRC" merge-base "$HEAD_HASH" "$UPSTREAM")
elif [ "$DO_CHANGES" = 1 ] || [ "$DO_COMMIT" = 1 ]; then
    die "unknown upstream ref: $UPSTREAM (see --upstream)"
fi

if [ -f /etc/debian_version ]; then
    BUILD_HOST="Debian $(cat /etc/debian_version) ($(uname -m))"
else
    BUILD_HOST=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")
fi

# Work area

if [ -z "$WORK" ]; then
    WORK=$(mktemp -d -t grub-rebuild.XXXXXX)
else
    mkdir -p "$WORK"
    WORK=$(cd "$WORK" && pwd)
fi
OUT=$(cd "$OUT" && pwd)
CHANGES_FILE=$(dirname "$OUT")/CHANGES_grub
LOGS=$WORK/logs
DEST=$WORK/dest
BUILD_SRC=$WORK/src
rm -rf "$LOGS" "$DEST"
mkdir -p "$LOGS" "$DEST"

cleanup() {
    git -C "$SRC" worktree remove --force "$BUILD_SRC" >/dev/null 2>&1 || true
    git -C "$SRC" worktree prune >/dev/null 2>&1 || true
    if [ "$KEEP_WORK" = 0 ]; then
        rm -rf "$WORK"
    else
        echo "Kept $WORK"
    fi
}
trap cleanup EXIT

log "GRUB $HEAD_HASH ($REV), build host: $BUILD_HOST"
log "Working directory: $WORK (logs in $LOGS)"

rm -rf "$BUILD_SRC"
git -C "$SRC" worktree add -q --detach "$BUILD_SRC" "$HEAD_HASH"

if [ "$DO_BOOTSTRAP" = 1 ]; then
    log "Bootstrapping (needs network unless GNULIB_SRCDIR is set)"
    (
        cd "$BUILD_SRC"
        ./bootstrap ${GNULIB_SRCDIR:+--gnulib-srcdir="$GNULIB_SRCDIR"} >"$LOGS/bootstrap.log" 2>&1
    ) || { tail -n 20 "$LOGS/bootstrap.log" >&2; die "bootstrap failed, see $LOGS/bootstrap.log"; }
fi

# Build

count=$(echo $PLATFORMS | wc -w)
platform_jobs=$(( (JOBS + count - 1) / count ))

build_platform() {
    local name=$1
    local build_dir=$WORK/build-$name

    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    cd "$build_dir"
    # shellcheck disable=SC2086
    "$BUILD_SRC/configure" ${CONFIGURE_ARGS[$name]} --disable-nls \
        --prefix="$PREFIX_BASE/$HOST_TAG/$name" >"$LOGS/$name.configure.log" 2>&1
    make -j"$platform_jobs" >"$LOGS/$name.make.log" 2>&1
    make install DESTDIR="$DEST" >"$LOGS/$name.install.log" 2>&1
}

log "Building: $PLATFORMS ($platform_jobs jobs each)"
declare -A PIDS
for platform in $PLATFORMS; do
    build_platform "$platform" &
    PIDS[$platform]=$!
done

failed=0
for platform in $PLATFORMS; do
    if wait "${PIDS[$platform]}"; then
        log "$platform: built"
    else
        failed=1
        echo "$platform: FAILED, last lines of the log:" >&2
        for f in make configure; do
            [ -s "$LOGS/$platform.$f.log" ] && { tail -n 15 "$LOGS/$platform.$f.log" >&2; break; }
        done
    fi
done
[ "$failed" = 0 ] || die "build failed, logs are in $LOGS (use --keep-work)"

# Make the installed trees relocatable: the build host has no access to
# $PREFIX_BASE, so the prefix was a fake path that is now made relative to the
# root of the Android source tree.

for platform in $PLATFORMS; do
    tree=$DEST/${PREFIX_BASE#//}/$HOST_TAG/$platform
    [ -d "$tree" ] || die "$tree was not installed"
    find "$tree" -type f -print0 |
        xargs -0 sed -i "s|$PREFIX_BASE/$HOST_TAG/$platform|.${PREFIX_BASE#/}/$HOST_TAG/$platform|g"
    if grep -rlF "$PREFIX_BASE/" "$tree" >/dev/null; then
        die "$platform: the fake prefix is still in the files"
    fi
    # The tools have to run
    "$tree/bin/grub-mkimage" --version >/dev/null ||
        die "$platform: grub-mkimage does not run"
    [ -d "$tree/lib/grub/$platform" ] || die "$platform: no modules were built"
done

# Install

for platform in $PLATFORMS; do
    tree=$DEST/${PREFIX_BASE#//}/$HOST_TAG/$platform
    mkdir -p "$OUT/$HOST_TAG"
    rm -rf "${OUT:?}/$HOST_TAG/$platform"
    cp -a "$tree" "$OUT/$HOST_TAG/$platform"
    log "$platform: installed to $OUT/$HOST_TAG/$platform"
done

if [ "$DO_CHANGES" = 1 ]; then
    git -C "$SRC" log --no-color "$UPSTREAM_BASE..$HEAD_HASH" >"$CHANGES_FILE"
    log "Updated $CHANGES_FILE"
fi

# Commits

commit_message() {
    local name=$1 extra=$2
    local packages=$APT_PACKAGES
    [ "$name" = arm64-efi ] && packages="$packages $APT_PACKAGES_ARM64"

    echo "bootmgr: grub: $HOST_TAG: $name: Update"
    echo
    echo "* Rebased onto upstream GRUB commit $UPSTREAM_BASE"
    echo "* HEAD commit: $HEAD_HASH"
    echo "* Build host: $BUILD_HOST"
    echo "* Built with grub/rebuild.sh"
    [ -z "$extra" ] || echo "$extra"
    echo
    echo '```'
    echo "sudo apt install $packages"
    echo "./bootstrap"
    echo "mkdir ../b-$name && cd ../b-$name"
    echo "../grub/configure ${CONFIGURE_ARGS[$name]} --disable-nls --prefix=$PREFIX_BASE/$HOST_TAG/$name"
    echo 'make -j$(nproc)'
    echo 'make install DESTDIR=$PWD/../dest'
    echo 'cd ../dest'
    echo "sed -i \"s|$PREFIX_BASE/$HOST_TAG/$name|.${PREFIX_BASE#/}/$HOST_TAG/$name|g\" \`find ${PREFIX_BASE#//}/$HOST_TAG/$name -type f\`"
    echo '```'
    if [ ${#TRAILERS[@]} -gt 0 ]; then
        echo
        printf '%s\n' "${TRAILERS[@]}"
    fi
}

if [ "$DO_COMMIT" = 1 ]; then
    first=1
    for platform in $PLATFORMS; do
        extra=
        paths=("$OUT/$HOST_TAG/$platform")
        if [ "$first" = 1 ] && [ "$DO_CHANGES" = 1 ]; then
            extra="* Update CHANGES_grub to match the patches"
            paths+=("$CHANGES_FILE")
        fi
        first=0
        git -C "$OUT" add -A -- "${paths[@]}"
        if git -C "$OUT" diff --cached --quiet -- "${paths[@]}"; then
            log "$platform: no changes, not committing"
            continue
        fi
        commit_message "$platform" "$extra" | git -C "$OUT" commit -q -F - -- "${paths[@]}"
        log "$platform: committed"
    done
fi

log "Done"
