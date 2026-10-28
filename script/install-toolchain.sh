#!/usr/bin/env bash
# install-toolchain.sh — install, update or uninstall the toolchain built in this checkout.
#
# The default action is install-or-update (idempotent). It runs the CMake install rule of a stage-1
# build tree into a prefix, records every file it wrote in <prefix>/lib/lean/.lean-install-manifest,
# and deletes files that a previous install produced but this one no longer does. --uninstall
# removes exactly the recorded files and then the directories that removal left empty; it never
# touches anything that was not recorded.
#
# Usage: ./script/install-toolchain.sh [options]
#   (no options)        install or update            (the default)
#   -u, --uninstall     remove a previous install
#       --tree NAME     llvm (default: build/release-llvm, has LLVM support) or gcc (build/release)
#       --prefix DIR    install prefix (default: /usr/local)
#       --status        report installed vs. freshly built toolchain, change nothing
#   -n, --dry-run       print what would change, change nothing
#   -y, --yes           do not ask for confirmation
#   -h, --help          show this help
#
# The prefix must be writable. When it is not and we are not root, the script re-executes itself
# through sudo, so `./script/install-toolchain.sh` handles /usr/local without extra ceremony.

set -euo pipefail

# Resolve symlinks so the script also runs from a link outside the repository.
self=$(readlink -f "${BASH_SOURCE[0]}")
self_dir=$(cd "$(dirname "$self")" && pwd)
if [ -f "$self_dir/CMakeLists.txt" ]; then
  repo_root=$self_dir
elif [ -f "$self_dir/../CMakeLists.txt" ]; then
  repo_root=$(cd "$self_dir/.." && pwd)
else
  printf 'install-toolchain: error: cannot find the Lean checkout from %s\n' "$self" >&2
  exit 1
fi
me="${self#"$repo_root"/}"
orig_args=("$@")

tree=llvm
prefix=/usr/local
action=install
dry_run=0
assume_yes=0

die()  { printf 'install-toolchain: error: %s\n' "$*" >&2; exit 1; }
note() { printf 'install-toolchain: %s\n' "$*"; }
warn() { printf 'install-toolchain: warning: %s\n' "$*" >&2; }

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$self"
}

while [ $# -gt 0 ]; do
  case $1 in
    -u|--uninstall) action=uninstall ;;
    --tree)         tree="${2:?--tree needs a value}"; shift ;;
    --prefix)       prefix="${2:?--prefix needs a value}"; shift ;;
    --status)       action=status ;;
    -n|--dry-run)   dry_run=1 ;;
    -y|--yes)       assume_yes=1 ;;
    -h|--help)      usage; exit 0 ;;
    *)              die "unknown argument '$1' (try --help)" ;;
  esac
  shift
done

# ---------------------------------------------------------------- sanity checks

[ -n "$prefix" ] || die "empty --prefix"
prefix="${prefix%/}"
case "$prefix" in
  "")  die "refusing to use '/' as the install prefix" ;;
  /*)  ;;
  *)   die "prefix must be absolute, got '$prefix'" ;;
esac
case "$prefix" in
  /|/usr|/etc|/home|/root|/var|/tmp|/boot|/bin|/sbin|/lib|/lib64|/opt|/dev|/proc|/sys)
    die "refusing to install directly into '$prefix'; use a subdirectory, e.g. $prefix/lean" ;;
esac

case "$tree" in
  llvm) stage="$repo_root/build/release-llvm/stage1"; hint="make -C build/release-llvm" ;;
  gcc)  stage="$repo_root/build/release/stage1";      hint="make -C build/release" ;;
  *)    die "--tree must be 'llvm' or 'gcc', got '$tree'" ;;
esac

manifest_file="$prefix/lib/lean/.lean-install-manifest"

path_writable() {
  local p=$1
  while [ ! -e "$p" ]; do p=$(dirname "$p"); [ "$p" = / ] && break; done
  [ -w "$p" ]
}

is_under_prefix() {
  case "$1" in
    "$prefix"/*) return 0 ;;
    *)           return 1 ;;
  esac
}

# Fail early — and without prompting for a password — when there is nothing to remove.
if [ "$action" = uninstall ] && [ ! -f "$manifest_file" ]; then
  if ! { [ -f "$stage/install_manifest.txt" ] && grep -qF "$prefix/" "$stage/install_manifest.txt" 2>/dev/null; }; then
    die "nothing to uninstall: no $manifest_file, and ${stage#"$repo_root"/}/install_manifest.txt records nothing under $prefix"
  fi
fi

# Re-execute under sudo when a *write* action needs a prefix we cannot write. Never for --status or
# --dry-run, which must stay safe to run unprivileged.
if [ "$dry_run" -eq 0 ] && [ "$action" != status ] && [ "$(id -u)" -ne 0 ] && ! path_writable "$prefix"; then
  command -v sudo >/dev/null 2>&1 || \
    die "'$prefix' is not writable and sudo is unavailable; rerun as root or use --prefix"
  note "elevating with sudo to write to $prefix"
  exec sudo -- "$self" "${orig_args[@]}"
fi

confirm() {
  [ "$assume_yes" -eq 1 ] && return 0
  [ -t 0 ] || die "stdin is not a terminal; pass --yes to confirm automatically"
  printf 'install-toolchain: %s [y/N] ' "$1"
  local reply; read -r reply || reply=no
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *)           return 1 ;;
  esac
}

lean_githash() {   # $1 = path to a lean binary
  "$1" --githash 2>/dev/null | head -1 || echo unknown
}

# ---------------------------------------------------------------- actions

do_status() {
  local installed="" built=""
  [ -x "$prefix/bin/lean" ] && installed=$(lean_githash "$prefix/bin/lean")
  [ -x "$stage/bin/lean" ]  && built=$(lean_githash "$stage/bin/lean")

  note "tree:      ${stage#"$repo_root"/}"
  note "prefix:    $prefix"
  note "built:     ${built:-<not built>}"
  note "installed: ${installed:-<not installed>}"

  if [ -n "$installed" ] && [ "$installed" = "$built" ]; then
    note "status:    up to date"
  elif [ -n "$installed" ]; then
    note "status:    out of date — run ./$me to update"
  else
    note "status:    not installed — run ./$me"
  fi

  if [ -x "$prefix/bin/lean" ]; then
    note "version:   $("$prefix/bin/lean" --version 2>/dev/null | head -1)"
    note "features:  $("$prefix/bin/lean" --features 2>/dev/null | head -1)"
  fi
  if [ -f "$manifest_file" ]; then
    note "manifest:  $(grep -c . "$manifest_file" || true) files recorded"
  else
    note "manifest:  none (uninstall would fall back to the build tree's list)"
  fi
}

do_install() {
  [ -f "$stage/cmake_install.cmake" ] || die "no install script at ${stage#"$repo_root"/} — build first: $hint"
  [ -x "$stage/bin/lean" ]            || die "no compiler at ${stage#"$repo_root"/}/bin/lean — build first: $hint"

  local built; built=$(lean_githash "$stage/bin/lean")
  note "tree:      ${stage#"$repo_root"/}"
  note "prefix:    $prefix"
  note "building  Lean commit ${built:0:10}$([ "$tree" = llvm ] && echo ' (LLVM enabled)' || true)"

  if [ -x "$prefix/bin/lean" ]; then
    note "replacing Lean commit $(lean_githash "$prefix/bin/lean" | cut -c1-10)"
  fi

  if [ "$dry_run" -eq 1 ]; then
    note "dry run — would run: cmake --install $stage --prefix $prefix"
    note "dry run — then record the installed file list in $manifest_file"
    note "dry run — and delete files a previous install left that this one does not produce"
    return 0
  fi

  # Snapshot the previous manifest before CMake rewrites the destination tree.
  local prev=""
  if [ -f "$manifest_file" ]; then
    prev=$(mktemp)
    grep -v '^$' "$manifest_file" | sort -u > "$prev" || true
  fi

  cmake --install "$stage" --prefix "$prefix"

  [ -f "$stage/install_manifest.txt" ] || die "cmake wrote no ${stage#"$repo_root"/}/install_manifest.txt; cannot record the install"
  grep -v '^$' "$stage/install_manifest.txt" | sort -u > "$manifest_file"
  local total; total=$(grep -c . "$manifest_file" || true)

  # Prune files the previous install wrote that this install no longer produces.
  if [ -n "$prev" ]; then
    local stale
    stale=$(comm -23 "$prev" "$manifest_file" || true)
    if [ -n "$stale" ]; then
      note "removing $(printf '%s\n' "$stale" | grep -c . || true) files left by the previous install"
      local f
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        if ! is_under_prefix "$f"; then
          warn "left alone (outside $prefix): $f"
          continue
        fi
        [ -e "$f" ] || [ -L "$f" ] || continue
        printf '  - %s\n' "$f"
        rm -f -- "$f"
      done <<< "$stale"
    fi
    rm -f -- "$prev"
  fi

  note "recorded $total files in $manifest_file"
  note "installed: $("$prefix/bin/lean" --version 2>/dev/null | head -1)"
  note "features:  $("$prefix/bin/lean" --features 2>/dev/null | head -1)"
  note "done — run ./$me --status to compare against the build tree"
}

do_uninstall() {
  local list_src=""
  if [ -f "$manifest_file" ]; then
    list_src="$manifest_file"
  elif [ -f "$stage/install_manifest.txt" ] && grep -qF "$prefix/" "$stage/install_manifest.txt" 2>/dev/null; then
    warn "no manifest at $manifest_file; falling back to ${stage#"$repo_root"/}/install_manifest.txt"
    list_src="$stage/install_manifest.txt"
  else
    die "nothing to uninstall: no $manifest_file, and no build-tree record for $prefix"
  fi

  local files count
  files=$(grep -v '^$' "$list_src" | sort -u || true)
  count=$(printf '%s\n' "$files" | grep -c . || true)
  [ "$count" -gt 0 ] || die "manifest $list_src is empty"

  note "prefix:    $prefix"
  note "recorded:  $count files in $list_src"
  printf '%s\n' "$files" \
    | sed "s|^$prefix/||" | cut -d/ -f1-2 | sort | uniq -c | sort -rn | head -8 | sed 's/^/  /'

  if [ "$dry_run" -eq 1 ]; then
    note "dry run — nothing removed; first few paths that would go:"
    printf '%s\n' "$files" | head -5 | sed 's/^/  - /'
    return 0
  fi

  confirm "remove $count files from $prefix?" || { note "aborted"; exit 1; }

  local removed=0 skipped=0 f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if ! is_under_prefix "$f"; then
      warn "left alone (outside $prefix): $f"
      skipped=$((skipped + 1))
      continue
    fi
    if [ -e "$f" ] || [ -L "$f" ]; then
      rm -f -- "$f"
      removed=$((removed + 1))
    fi
  done <<< "$files"

  rm -f -- "$manifest_file"
  note "removed $removed files$([ "$skipped" -gt 0 ] && echo ", left $skipped alone")"

  # Prune directories this removal emptied — never recursively, only if already empty.
  local d
  for d in "$prefix/lib/lean" "$prefix/include/lean" "$prefix/share/lean" "$prefix/src/lean"; do
    [ -d "$d" ] && find "$d" -depth -type d -empty -delete 2>/dev/null || true
  done
  for d in "$prefix/bin" "$prefix/lib" "$prefix/include" "$prefix/share" "$prefix/src"; do
    [ -d "$d" ] && rmdir "$d" 2>/dev/null || true
  done
  rmdir "$prefix" 2>/dev/null || true   # only if it is now empty; never recursive

  if [ -x "$prefix/bin/lean" ]; then
    warn "a lean binary still exists at $prefix/bin/lean — not recorded, left in place"
  else
    note "uninstalled from $prefix"
  fi
  [ -d "$prefix" ] || note "prefix $prefix is now gone"
}

case "$action" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  status)    do_status ;;
esac
