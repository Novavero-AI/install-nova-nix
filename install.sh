#!/bin/sh
# Install nova-nix for one user on Linux or macOS, upgrade it, remove it, or
# set up its store alone.
#
#   curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/Novavero-AI/install-nova-nix/v1/install.sh | sh
#
# Arguments go after `sh -s --`; --help lists them. The script downloads a
# release archive and the release's SHA256SUMS, refuses an archive that does
# not match, sets up /nix for the store, unpacks the archive into
# ~/.nova-nix and adds its bin/ to PATH in the shell startup files.
#
# Nothing happens until main, on the last line, so a download cut short does
# nothing.

set -eu
# What the installer and root write is readable by everyone, whatever umask
# the calling shell had, as upstream's installer sets.
umask 022

repo=Novavero-AI/nova-nix
install_dir=.nova-nix
nix_root=/nix
store=/nix/store
# Upstream Nix keeps its database under here; nova-nix refuses to build in a
# store that database also manages.
upstream_state=/nix/var/nix
download_retries=3
usage_status=2
root_uid=0

# The line added to each shell startup file. It expands HOME when the shell
# starts and adds bin/ only once, so a file read twice leaves PATH as it was.
# shellcheck disable=SC2016 # The variables expand in the startup file, not here.
bin_ref='${HOME}/'"${install_dir}"'/bin'
# shellcheck disable=SC2016
path_line=$(printf 'case ":${PATH}:" in *":%s:"*) ;; *) export PATH="%s:${PATH}" ;; esac # added by the nova-nix installer' "${bin_ref}" "${bin_ref}")
# fish reads none of the files above; it reads every file in its conf.d.
# shellcheck disable=SC2016
fish_line='if not contains -- "$HOME/'"${install_dir}"'/bin" $PATH; set -gx PATH "$HOME/'"${install_dir}"'/bin" $PATH; end # added by the nova-nix installer'

# macOS: the volume that holds /nix, how fstab mounts it, and the
# LaunchDaemon that mounts it at boot. The volume is case-sensitive, so
# names in the store that differ only in case need no case-hack.
volume_label='nova-nix Store'
volume_fs='Case-sensitive APFS'
fstab=/etc/fstab
fstab_options=rw,noauto,nobrowse,suid,owners
synthetic_conf=/etc/synthetic.conf
synthetic_line=nix
daemon_label=ai.novavero.nova-nix.store
daemon_plist=/Library/LaunchDaemons/${daemon_label}.plist

# System tools by absolute path. sudo on macOS keeps the caller's PATH, in
# which a directory the user can write, such as Homebrew's, comes first, so a
# name looked up there could run anything as root. chown, and the flag stat
# takes a format with, are set with the platform.
sudo=/usr/bin/sudo
env=/usr/bin/env
tee=/usr/bin/tee
touch=/usr/bin/touch
mktemp=/usr/bin/mktemp
find=/usr/bin/find
mkdir=/bin/mkdir
rmdir=/bin/rmdir
chmod=/bin/chmod
mv=/bin/mv
rm=/bin/rm
ed=/bin/ed
stat=/usr/bin/stat
diskutil=/usr/sbin/diskutil
launchctl=/bin/launchctl
plutil=/usr/bin/plutil
vifs=/usr/sbin/vifs
fdesetup=/usr/bin/fdesetup
apfs_util=/System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util
# Where a volume not yet mounted is mounted for a moment, to see whose it is.
look_parent=/private/tmp

say() { printf '%s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Install nova-nix for this user, upgrade or remove it, or set up its store alone.

Usage: install.sh [--version VERSION | --from DIR]
       install.sh --store-only
       install.sh --uninstall [--remove-store]

  --version VERSION  install this release (for example 0.10.0.0), not the latest
  --from DIR         install the archive in DIR, checked against DIR/SHA256SUMS
  --store-only       set up /nix for the store, and install nothing
  --uninstall        remove nova-nix and the PATH lines this script added
  --remove-store     with --uninstall, also remove /nix/store and its setup
  -h, --help         show this help

Run it again to upgrade: the install is replaced by the release it names.
EOF
}

usage_error() {
  printf 'error: %s\n\n' "$*" >&2
  usage >&2
  exit "${usage_status}"
}

# A release version: digits separated by dots, with an optional leading v.
# It becomes a path segment of the download URL, so nothing else is let in.
is_release() {
  case ${1#v} in
    '' | .* | *. | *..* | *[!0-9.]*) return 1 ;;
  esac
}

# Runs a command as root, through sudo unless this already is root. Every
# command given to it is named by absolute path, and anything it writes
# arrives on stdin or as an argument, never from a file the user can change.
as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif [ -x "${sudo}" ]; then
    "${sudo}" "$@"
  else
    die "this step needs root and ${sudo} is not installed; run the installer as root"
  fi
}

# ---------------------------------------------------------------------------
# Platform
# ---------------------------------------------------------------------------

# The user's primary group when it is theirs alone, or nothing: a group
# named after the user that lists no members and is no other account's
# primary group. A user-private group can still be given members, and
# macOS puts every user in staff.
user_private_group() {
  group=$(id -gn)
  [ "${group}" = "$(id -un)" ] || return 0
  command -v getent >/dev/null 2>&1 || return 0
  entry=$(getent group "${group}") || return 0
  members=$(printf '%s\n' "${entry}" | cut -d: -f4)
  [ -z "${members}" ] || return 0
  others=$(getent passwd | awk -F: -v gid="$(id -g)" -v user="$(id -un)" '$4 == gid && $1 != user { print $1; exit }') || return 0
  [ -z "${others}" ] || return 0
  id -g
}

detect_platform() {
  case $(uname -s) in
    Linux) os=linux ;;
    Darwin) os=macos ;;
    *) die "nova-nix publishes no archive for $(uname -s); on Windows, use install.ps1" ;;
  esac
  case $(uname -m) in
    x86_64 | amd64) arch=x64 ;;
    arm64 | aarch64) arch=arm64 ;;
    *) arch=$(uname -m) ;;
  esac
  # A shell running under Rosetta reports x86_64 on Apple silicon, where the
  # arm64 build runs natively.
  if [ "${os}" = macos ] && [ "$(sysctl -in hw.optional.arm64 2>/dev/null)" = 1 ]; then
    arch=arm64
  fi
  case ${os}-${arch} in
    linux-x64 | macos-arm64) ;;
    *) die "nova-nix publishes no archive for ${os}-${arch}" ;;
  esac
  stem=nova-nix-${os}-${arch}
  archive=${stem}.tar.gz
  case ${os} in
    linux)
      requirement='it needs glibc 2.38 or newer, libgmp.so.10 and libz.so.1'
      chown=/bin/chown
      stat_flag=-c
      private_group=$(user_private_group)
      ;;
    macos)
      requirement='it needs macOS 26 or newer'
      chown=/usr/sbin/chown
      stat_flag=-f
      private_group=
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Download and verification
# ---------------------------------------------------------------------------

download() {
  say "Downloading $1"
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --retry "${download_retries}" --output "$2" "$1" \
    || die "downloading $1 failed"
}

# GitHub answers .../releases/latest with a redirect to the newest release's
# tag. Reading the version from it names one release for both downloads,
# where .../releases/latest/download/ could serve them from two releases if
# one is published in between.
latest_version() {
  url=https://github.com/${repo}/releases/latest
  answer=$(curl --silent --show-error --proto '=https' --tlsv1.2 \
    --retry "${download_retries}" --output /dev/null --write-out '%{http_code} %{redirect_url}' "${url}") \
    || die "could not reach ${url}"
  status=${answer%% *}
  location=${answer#* }
  case ${status} in
    3??) ;;
    *) die "GitHub answered ${url} with HTTP ${status}" ;;
  esac
  tag_prefix=https://github.com/${repo}/releases/tag/v
  case ${location} in
    "${tag_prefix}"*) latest=${location#"${tag_prefix}"} ;;
    *) die "${repo} has no release to install" ;;
  esac
  is_release "${latest}" || die "the latest release is not tagged with a version"
  printf '%s\n' "${latest}"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sum=$(sha256sum -b "$1")
  elif command -v shasum >/dev/null 2>&1; then
    sum=$(shasum -a 256 -b "$1")
  elif command -v openssl >/dev/null 2>&1; then
    sum=$(openssl dgst -sha256 -r "$1")
  else
    die "no sha256sum, shasum or openssl to check the download with"
  fi || die "could not compute the SHA-256 of $1"
  printf '%s\n' "${sum%% *}" | tr 'A-F' 'a-f'
}

# Checks the archive against the one line of SHA256SUMS that names it. The
# name is compared as a string, since it is full of dots a pattern would let
# match anything.
verify() {
  expected=$(awk -v name="${archive}" '{ file = $2; sub(/^\*/, "", file); if (file == name) print $1 }' \
    "${scratch}/SHA256SUMS" | tr 'A-F' 'a-f') || die "could not read SHA256SUMS"
  case ${expected} in
    '') die "SHA256SUMS lists no checksum for ${archive}" ;;
    *[!0-9a-f]*) die "SHA256SUMS does not list exactly one checksum for ${archive}" ;;
  esac
  actual=$(sha256_of "${scratch}/${archive}") || exit 1
  if [ "${actual}" != "${expected}" ]; then
    die "${archive} does not match its checksum in SHA256SUMS (expected ${expected}, got ${actual}); refusing to install it"
  fi
  say "${archive} matches its checksum in SHA256SUMS"
}

fetch_release() {
  if [ -n "${from}" ]; then
    [ -d "${from}" ] || die "${from} is not a directory"
    cp "${from}/${archive}" "${scratch}/${archive}" || die "${from} holds no ${archive}"
    cp "${from}/SHA256SUMS" "${scratch}/SHA256SUMS" || die "${from} holds no SHA256SUMS"
    return 0
  fi
  command -v curl >/dev/null 2>&1 || die "curl is needed to download nova-nix"
  if [ -z "${version}" ]; then
    version=$(latest_version) || exit 1
  fi
  base=https://github.com/${repo}/releases/download/v${version}
  download "${base}/${archive}" "${scratch}/${archive}"
  download "${base}/SHA256SUMS" "${scratch}/SHA256SUMS"
}

# Unpacks the verified archive and runs the nova-nix in it, so one that cannot
# run here, or reports another version, is refused before anything changes.
unpack() {
  mkdir "${scratch}/unpack" || die "could not create ${scratch}/unpack"
  tar -xzf "${scratch}/${archive}" -C "${scratch}/unpack" || die "could not unpack ${archive}"
  staged=${scratch}/unpack/${stem}
  [ -f "${staged}/bin/nova-nix" ] || die "${archive} does not hold ${stem}/bin/nova-nix"
  reported=$("${staged}/bin/nova-nix" --version) \
    || die "the nova-nix in ${archive} does not run on this machine: ${requirement}"
  case ${reported} in
    'nova-nix '*) ;;
    *) die "the nova-nix in ${archive} reports its version as '${reported}'" ;;
  esac
  if [ -n "${version}" ] && [ "${reported}" != "nova-nix ${version}" ]; then
    die "${archive} holds ${reported}, not nova-nix ${version}"
  fi
}

# ---------------------------------------------------------------------------
# The install directory
# ---------------------------------------------------------------------------

is_install() {
  [ -d "$1" ] && [ ! -L "$1" ] && [ -f "$1/bin/nova-nix" ]
}

# Refuses to go on when the install directory holds something else, before
# anything is downloaded or changed.
check_root() {
  if { [ -e "${root}" ] || [ -L "${root}" ]; } && ! is_install "${root}"; then
    die "${root} exists and does not hold a nova-nix install; move it away, then run this again"
  fi
}

# Moves the unpacked archive into place. The previous install is moved to a
# directory of its own beside it, outside the scratch directory, so that a
# failed or interrupted move leaves it for cleanup to put back rather than
# deleting it with the scratch directory.
place() {
  if [ -e "${root}" ]; then
    previous=$(mktemp -d "${root}.previous.XXXXXX") || die "could not create a directory beside ${root}"
    mv "${root}" "${previous}/install" || die "could not move the existing install in ${root} aside"
  fi
  mv "${staged}" "${root}" || die "could not move nova-nix into ${root}"
  if [ -n "${previous}" ]; then
    rm -rf "${previous}" || warn "could not remove the previous install in ${previous}"
    previous=
  fi
}

# Whether fstab holds this installer's line for volume $1.
fstab_records() {
  [ -f "${fstab}" ] && grep -qxF -e "$(fstab_line "$1")" "${fstab}"
}

# Deletes the volume this run made, which the run ended before fstab
# recorded, so it is not left as a volume of no record that no later run
# takes over or removes. Only once it is shown to be root's and to hold
# nothing anyone put there, on a mount point of root's as
# check_volume_owner looks; otherwise it is left, and named.
discard_made_volume() {
  mounted=$(volume_field "${made_uuid}" MountPoint) || mounted=
  if [ -z "${mounted}" ]; then
    look=$(as_root "${mktemp}" -d "${look_parent}/nova-nix-volume.XXXXXX") || look=
    if [ -z "${look}" ] || ! as_root "${diskutil}" mount -mountPoint "${look}" "${made_uuid}" >&2; then
      warn "the volume ${made_uuid} this run made, which fstab does not record, is left in place"
      return 0
    fi
    mounted=${look}
  fi
  if [ "$(owner_of "${mounted}")" = "${root_uid}" ] && (check_root_unclaimed "${mounted}") 2>/dev/null; then
    as_root "${diskutil}" unmount force "${mounted}" >&2 || :
    if as_root "${diskutil}" apfs deleteVolume "${made_uuid}" >&2; then
      say "Deleted the volume ${made_uuid} this run made, which fstab did not record yet"
      return 0
    fi
  fi
  warn "the volume ${made_uuid} this run made, which fstab does not record, is left in place"
}

# Runs on every exit. A previous install still set aside goes back unless
# the new one is in its place, and is named if it cannot.
cleanup() {
  if [ -n "${made_uuid}" ] && ! fstab_records "${made_uuid}"; then
    discard_made_volume
  fi
  if [ -n "${previous}" ] && [ -e "${previous}/install" ]; then
    if [ -e "${root}" ]; then
      rm -rf "${previous}" || warn "could not remove the previous install in ${previous}"
    elif mv "${previous}/install" "${root}"; then
      rmdir "${previous}" || :
      say "Put the previous install back in ${root}"
    else
      warn "the previous install is in ${previous}/install; move it back to ${root}"
    fi
  elif [ -n "${previous}" ]; then
    rmdir "${previous}" 2>/dev/null || :
  fi
  if [ -n "${look}" ]; then
    as_root "${diskutil}" unmount force "${look}" >&2 || :
    as_root "${rmdir}" "${look}" || :
  fi
  if [ -n "${scratch}" ]; then
    rm -rf "${scratch}"
  fi
}

# ---------------------------------------------------------------------------
# PATH in the shell startup files
# ---------------------------------------------------------------------------

zsh_env() { printf '%s\n' "${ZDOTDIR:-${HOME}}/.zshenv"; }
fish_conf_dir() { printf '%s\n' "${XDG_CONFIG_HOME:-${HOME}/.config}/fish/conf.d"; }
fish_conf() { printf '%s\n' "$(fish_conf_dir)/nova-nix.fish"; }

# Login shells read ~/.profile, or bash's own login file in its place when
# one exists, and interactive bash reads ~/.bashrc; fish reads its conf.d.
# zsh reads .zshenv in every shell, from ZDOTDIR when that is set and from
# HOME otherwise, and a ZDOTDIR exported from ~/.zshenv is set only after the
# first shell has read that file, so both get the line when they differ.
# ~/.profile is created if missing, and the zsh and fish files when that
# shell is installed.
add_path_lines() {
  set -- "${HOME}/.profile"
  for name in .bash_profile .bash_login .bashrc; do
    if [ -f "${HOME}/${name}" ]; then set -- "$@" "${HOME}/${name}"; fi
  done
  if command -v zsh >/dev/null 2>&1; then
    set -- "$@" "${HOME}/.zshenv"
    if [ "$(zsh_env)" != "${HOME}/.zshenv" ]; then set -- "$@" "$(zsh_env)"; fi
  fi
  for rc in "$@"; do
    add_path_line "${rc}" "${path_line}"
  done
  covered='sh bash dash ksh zsh'
  if command -v fish >/dev/null 2>&1; then
    mkdir -p "$(fish_conf_dir)" || die "could not create $(fish_conf_dir)"
    add_path_line "$(fish_conf)" "${fish_line}"
    covered="${covered} fish"
  fi
  shell_name=${SHELL:-}
  shell_name=${shell_name##*/}
  if [ -n "${shell_name}" ]; then
    case " ${covered} " in
      *" ${shell_name} "*) ;;
      *) say "Your shell, ${shell_name}, reads none of those files: add ${root}/bin to its PATH" ;;
    esac
  fi
}

add_path_line() {
  if [ -f "$1" ] && grep -qxF -e "$2" "$1"; then
    return 0
  fi
  if [ -e "$1" ] && [ ! -w "$1" ]; then
    warn "cannot write to $1; add ${root}/bin to PATH there yourself"
    return 0
  fi
  if [ -s "$1" ] && [ -n "$(tail -c 1 "$1")" ]; then
    printf '\n' >>"$1" || die "could not write to $1"
  fi
  printf '%s\n' "$2" >>"$1" || die "could not write to $1"
  say "Added nova-nix to PATH in $1"
}

# Removes the line wherever it is, whatever made it worth adding there, and
# the fish file, which holds nothing else.
remove_path_lines() {
  for rc in "${HOME}/.profile" "${HOME}/.bash_profile" "${HOME}/.bash_login" \
    "${HOME}/.bashrc" "${HOME}/.zshenv" "$(zsh_env)"; do
    remove_line "${rc}" "${path_line}"
  done
  fish=$(fish_conf)
  remove_line "${fish}" "${fish_line}"
  if [ -f "${fish}" ] && [ ! -s "${fish}" ]; then
    rm "${fish}" || warn "could not remove the empty ${fish}"
  fi
}

# Removes every line equal to $2 from file $1, rewriting it in place so a
# symbolic link stays a link and the file keeps its owner and mode. The
# lines kept are written beside it first, outside the scratch directory, so
# that a rewrite cut short leaves them there to be named. A file it cannot
# write is named and left as it is.
remove_line() {
  if ! { [ -f "$1" ] && grep -qxF -e "$2" "$1"; }; then
    return 0
  fi
  if [ ! -w "$1" ]; then
    warn "cannot write to $1; remove the line ending '# added by the nova-nix installer' there yourself"
    return 0
  fi
  kept=$(mktemp "$1.nova-nix.XXXXXX") || die "could not create a file beside $1"
  grep -vxF -e "$2" "$1" >"${kept}" || [ "$?" -eq 1 ] || die "could not read $1"
  cat "${kept}" >"$1" || die "could not rewrite $1; its other lines are in ${kept}"
  rm -f "${kept}"
  say "Removed nova-nix from PATH in $1"
}

# ---------------------------------------------------------------------------
# Whose the store is
# ---------------------------------------------------------------------------
#
# Every run, install and uninstall alike, establishes before it changes
# anything that the store is this user's: the directory holding it is this
# user's, or root's while it holds no store yet, which this user may then
# claim, and that directory and everything in its store can be changed by
# no other account. Anything else, including anything whose owner cannot be
# read, is refused with nothing changed, on this run and on every run after.

# The numeric owner of $1, or of the directory a link there leads to.
owner_of() { "${stat}" "${stat_flag}" %u "$1/"; }

# Prints the first entry of the tree at $1 that an account other than this
# user can write, without following links, whose own mode says nothing; the
# arguments after $1 go to find before the test. A group-writable entry is
# refused unless its group is this user's own private group. Fails when
# part of the tree cannot be read.
writable_by_others() {
  path=$1
  shift
  if [ -n "${private_group}" ]; then
    find "${path}" "$@" ! -type l \( -perm -0002 -o \( -perm -0020 ! -group "${private_group}" \) \) -print -quit
  else
    find "${path}" "$@" ! -type l \( -perm -0002 -o -perm -0020 \) -print -quit
  fi
}

# Prints the first entry of the tree at $1, links included and not followed,
# that this user does not own. Fails when part of the tree cannot be read.
not_mine() { find "$1" ! -user "$(id -u)" -print -quit; }

# Prints the first entry inside system directory $1 that is a link or that
# neither root nor this user owns. What macOS keeps there may be this
# user's own, as the per-user trash .Trashes/501 is, or root's. Root lists
# it, since these directories' modes let no one else. Fails when it cannot
# be read.
foreign_system_entry() {
  as_root "${find}" "$1" -mindepth 1 \( -type l -o \( ! -user "${root_uid}" ! -user "$(id -u)" \) \) -print -quit
}

# Dies unless directory $1, root's, holds nothing anyone put there, so it is
# no one's yet: on Linux nothing at all, and on macOS, a volume's root, only
# entries the system makes there itself, each a directory of root's, not a
# link and writable by no group or other, holding only what is root's or
# this user's, which are left as they are. Those are .fseventsd, the File
# System Events log Apple's File System Events Programming Guide places at
# a volume's root, and .Trashes, .Spotlight-V100 and .TemporaryItems, which
# Finder, Spotlight and the system make on volumes as they are used
# (observed, not documented). Fails when $1 cannot be read, since what it
# holds, and whose, cannot then be told.
check_root_unclaimed() {
  shown=${2:-$1}
  case ${os} in
    macos)
      held=$(find "$1/" -mindepth 1 -maxdepth 1 ! \( -user "${root_uid}" -type d ! -perm -0020 ! -perm -0002 \
        \( -name .fseventsd -o -name .Trashes -o -name .Spotlight-V100 -o -name .TemporaryItems \) \) -print -quit) \
        || die "${shown} is root's and cannot be read, so what it holds cannot be told; leaving it in place"
      [ -z "${held}" ] || die "${shown} belongs to uid ${root_uid} and is not empty, so it is not $(id -un)'s to take; leaving it in place"
      for entry in .fseventsd .Trashes .Spotlight-V100 .TemporaryItems; do
        if [ -d "$1/${entry}" ]; then
          inside=$(foreign_system_entry "$1/${entry}") \
            || die "cannot read ${entry} in ${shown}, so what it holds cannot be told; leaving it in place"
          [ -z "${inside}" ] || die "${entry} in ${shown} holds an entry that is a link or another account's, so it is not $(id -un)'s to take; leaving it in place"
        fi
      done
      ;;
    linux)
      held=$(find "$1/" -mindepth 1 -maxdepth 1 -print -quit) \
        || die "${shown} is root's and cannot be read, so what it holds cannot be told; leaving it in place"
      [ -z "${held}" ] || die "${shown} belongs to uid ${root_uid} and is not empty, so it is not $(id -un)'s to take; leaving it in place"
      ;;
  esac
}

# Dies unless the store in directory $1 is this user's, as above. Sets
# claim=yes when $1 is root's and holds no one's entries, for the caller to
# give to this user, and claim=no when it is this user's already. A
# directory of root's is taken over only when $2 is "recorded", meaning the
# caller knows it to be this installer's (/nix itself on Linux, a volume of
# its record on macOS), so a volume it has no record of is never taken. $3,
# when given, is the volume whose root $1 is, which messages name in place
# of a mount point made only to look.
check_store_owner() {
  claim=no
  if [ -n "${3:-}" ]; then
    root_shown="the root of the volume $3"
    store_shown="the store on the volume $3"
  else
    root_shown=$1
    store_shown=$1/store
  fi
  [ -d "$1" ] || die "${root_shown} is not a directory; leaving it in place"
  owner=$(owner_of "$1") || die "cannot read the owner of ${root_shown}, so whose store it holds cannot be told; leaving it in place"
  if [ "${owner}" = "$(id -u)" ]; then
    :
  elif [ "${owner}" = "${root_uid}" ] && [ "${2:-}" = recorded ]; then
    check_root_unclaimed "$1" "${root_shown}"
    claim=yes
  elif [ "${owner}" = "${root_uid}" ]; then
    die "${root_shown} belongs to uid ${root_uid}, and this installer has no record of it, so it is not taken over; leaving it in place"
  else
    die "${root_shown} belongs to uid ${owner}, not to $(id -un), so the store in it is another account's; leaving it in place"
  fi
  found=$(writable_by_others "$1/" -prune) || die "cannot read ${root_shown}; leaving it in place"
  [ -z "${found}" ] || die "accounts other than $(id -un) can change ${root_shown}; leaving it in place"
  if [ -L "$1/store" ]; then
    die "${store_shown} is a symbolic link; leaving it in place"
  fi
  if [ -e "$1/store" ]; then
    found=$(not_mine "$1/store") \
      || die "cannot read all of ${store_shown}, so whose it is cannot be told; leaving it in place"
    [ -z "${found}" ] || die "${store_shown}${found#"$1/store"} belongs to another account, so the store is not $(id -un)'s alone; leaving it in place"
    found=$(writable_by_others "$1/store") \
      || die "cannot read all of ${store_shown}, so whose it is cannot be told; leaving it in place"
    [ -z "${found}" ] || die "accounts other than $(id -un) can change ${store_shown}${found#"$1/store"}; leaving the store in place"
  fi
}

# ---------------------------------------------------------------------------
# The store on Linux: /nix, owned by this user
# ---------------------------------------------------------------------------

upstream_present() { [ -e "${upstream_state}" ]; }

upstream_warning() {
  warn "upstream Nix manages ${store} on this machine, and nova-nix does not build in a store it manages; give nova-nix a store of its own with --store DIR"
}

check_store_writable() {
  for path in "${nix_root}" "${store}"; do
    if [ -e "${path}" ] && [ ! -w "${path}" ]; then
      die "${path} exists, but $(id -un) cannot write to it; leaving it in place"
    fi
  done
}

setup_store_linux() {
  if [ -L "${nix_root}" ]; then
    die "${nix_root} is a symbolic link; leaving it in place"
  fi
  if [ ! -e "${nix_root}" ]; then
    say "Creating ${nix_root} for the store, owned by $(id -un); this needs root"
    as_root "${mkdir}" -m 0755 "${nix_root}" || die "could not create ${nix_root}"
    as_root "${chown}" "$(id -u)" "${nix_root}" || die "could not give ${nix_root} to $(id -un)"
  fi
  check_store_owner "${nix_root}" recorded
  if [ "${claim}" = yes ]; then
    say "Giving ${nix_root}, which is root's and empty, to $(id -un); this needs root"
    as_root "${chown}" "$(id -u)" "${nix_root}" || die "could not give ${nix_root} to $(id -un)"
  fi
  check_store_writable
}

# What --remove-store removes on Linux is /nix/store, and /nix once nothing
# else is in it. A link is refused rather than followed: chmod -R would
# change what it leads to and rm would remove only the link.
check_store_removable_linux() {
  for path in "${nix_root}" "${store}"; do
    if [ -L "${path}" ]; then
      die "${path} is a symbolic link; leaving everything in place"
    fi
  done
  if [ -e "${nix_root}" ]; then
    check_store_owner "${nix_root}" recorded
  fi
}

remove_store_linux() {
  if [ -d "${store}" ]; then
    # Store paths are read-only, and an entry cannot be unlinked from a
    # read-only directory. chmod -R follows no symbolic link below the store.
    chmod -R u+w "${store}" || die "could not make ${store} writable to remove it"
    rm -rf "${store}" || die "could not remove ${store}"
    say "Removed ${store}"
  fi
  if [ -d "${nix_root}" ]; then
    if [ -n "$(find "${nix_root}/" -mindepth 1 -maxdepth 1 -print -quit)" ] || [ "$(owner_of "${nix_root}")" != "$(id -u)" ]; then
      say "Left ${nix_root} in place: it holds more than the store, or is not $(id -un)'s"
    else
      as_root "${rmdir}" "${nix_root}" || die "could not remove ${nix_root}"
      say "Removed ${nix_root}"
    fi
  fi
}

# ---------------------------------------------------------------------------
# The store on macOS: /nix on an APFS volume of its own
# ---------------------------------------------------------------------------
#
# The root volume is read-only, so /nix exists only as a mount point that
# /etc/synthetic.conf asks for. The volume is mounted there at boot by a
# LaunchDaemon, with the mount options /etc/fstab gives it, as upstream Nix's
# installer does (scripts/create-darwin-volume.sh). It is always in the APFS
# container that / is in, as upstream requires of its own volume: a volume
# with the same name on another disk, such as a cloned backup, is never
# adopted or deleted.

# One field of `diskutil info` for a device, a mount point or a volume UUID.
# Fails when diskutil knows no such volume.
volume_field() {
  "${diskutil}" info -plist "$1" 2>/dev/null | "${plutil}" -extract "$2" raw -o - - 2>/dev/null
}

# Whether volume $1 is this installer's: it has the installer's label and is
# in the container that / is in.
is_store_volume() {
  [ "$(volume_field "$1" VolumeName)" = "${volume_label}" ] \
    && [ "$(volume_field "$1" APFSContainerReference)" = "${container}" ]
}

# Dies unless volume $1, which $2 names, is this installer's.
check_store_volume() {
  label=$(volume_field "$1" VolumeName) \
    || die "$2 volume $1, which does not exist; remove that line with sudo vifs"
  if ! is_store_volume "$1"; then
    die "$2 the volume '${label}' ($1), which this installer did not create in ${container}; leaving it in place"
  fi
}

# The UUIDs of the volumes with this installer's label in /'s container, one
# per line.
labeled_volumes() {
  list=$("${diskutil}" apfs list -plist "${container}") || die "could not list the volumes in ${container}"
  index=0
  while name=$(printf '%s\n' "${list}" | "${plutil}" -extract "Containers.0.Volumes.${index}.Name" raw -o - - 2>/dev/null); do
    if [ "${name}" = "${volume_label}" ]; then
      printf '%s\n' "${list}" | "${plutil}" -extract "Containers.0.Volumes.${index}.APFSVolumeUUID" raw -o - - \
        || die "could not read the volumes in ${container}"
    fi
    index=$((index + 1))
  done
}

check_uuid() {
  case $1 in
    '' | *[!0-9A-Fa-f-]*) die "'$1' is not a volume UUID" ;;
  esac
}

# The device fstab mounts at /nix, such as UUID=..., or nothing.
fstab_nix_spec() {
  if [ -f "${fstab}" ]; then
    awk -v mount="${nix_root}" '$1 !~ /^#/ && $2 == mount { print $1; exit }' "${fstab}" \
      || die "could not read ${fstab}"
  fi
}

fstab_line() { printf 'UUID=%s %s apfs %s\n' "$1" "${nix_root}" "${fstab_options}"; }

# Adds or removes line $2 of fstab through vifs, which holds the file's lock
# while its editor runs. The editor is ed, which reads its commands from
# stdin and no startup file, so root runs nothing the user can change. ed
# cannot open a file that does not exist, so an empty fstab is made first.
edit_fstab() {
  if [ ! -e "${fstab}" ]; then
    as_root "${touch}" "${fstab}" || die "could not create ${fstab}"
  fi
  case $1 in
    add)
      # shellcheck disable=SC2016 # $a is ed's command to append after the last line.
      commands=$(printf '%s\n' '$a' "$2" . w q)
      ;;
    remove)
      pattern=$(printf '%s\n' "$2" | sed 's/[][\.*^$|]/\\&/g')
      commands=$(printf '%s\n' "g|^${pattern}\$|d" w q)
      ;;
  esac
  printf '%s\n' "${commands}" | as_root "${env}" EDITOR="${ed}" "${vifs}" >/dev/null \
    || die "could not edit ${fstab}"
  case $1 in
    add) grep -qxF -e "$2" "${fstab}" ;;
    remove) ! grep -qxF -e "$2" "${fstab}" ;;
  esac || die "editing ${fstab} did not $1 the line for ${nix_root}"
}

append_line_as_root() {
  {
    if [ -s "$1" ] && [ -n "$(tail -c 1 "$1")" ]; then printf '\n'; fi
    printf '%s\n' "$2"
  } | as_root "${tee}" -a "$1" >/dev/null || die "could not add '$2' to $1"
}

# Removes the line from a root-owned file, and the file once nothing else is
# left in it. The lines kept are written to a new file beside it, renamed
# over it once complete, so a write cut short leaves the file as it was.
remove_line_as_root() {
  if ! { [ -f "$1" ] && grep -qxF -e "$2" "$1"; }; then
    return 0
  fi
  kept=$(grep -vxF -e "$2" "$1") || [ "$?" -eq 1 ] || die "could not read $1"
  if [ -n "${kept}" ]; then
    printf '%s\n' "${kept}" | as_root "${tee}" "$1.nova-nix-new" >/dev/null || die "could not rewrite $1"
    as_root "${mv}" "$1.nova-nix-new" "$1" || die "could not rewrite $1; its other lines are in $1.nova-nix-new"
  else
    as_root "${rm}" "$1" || die "could not remove $1"
  fi
}

setup_synthetic() {
  tab=$(printf '\t')
  if [ -f "${synthetic_conf}" ] && grep -q "^${synthetic_line}${tab}" "${synthetic_conf}"; then
    die "${synthetic_conf} makes ${nix_root} a symbolic link; remove that line, restart, then run this again"
  fi
  if ! { [ -f "${synthetic_conf}" ] && grep -qxF -e "${synthetic_line}" "${synthetic_conf}"; }; then
    say "Adding ${nix_root} to ${synthetic_conf}"
    append_line_as_root "${synthetic_conf}" "${synthetic_line}"
  fi
  if [ ! -d "${nix_root}" ]; then
    # apfs.util -t creates what synthetic.conf names without a restart. Its
    # exit status does not say whether it did (upstream's installer ignores
    # it too), so the directory is what is checked.
    as_root "${apfs_util}" -t || :
    [ -d "${nix_root}" ] || die "macOS did not create ${nix_root}; restart, then run this again"
  fi
}

# Sets uuid to the volume for /nix, changing nothing: the one fstab names,
# which must be this installer's, or the one in /'s container with this
# installer's label, or nothing when one is to be made.
choose_volume() {
  uuid=
  spec=$(fstab_nix_spec)
  case ${spec} in
    '')
      uuid=$(labeled_volumes) || exit 1
      case ${uuid} in
        *"
"*) die "${container} holds more than one volume named '${volume_label}'; delete the ones not in use with diskutil apfs deleteVolume, then run this again" ;;
      esac
      ;;
    UUID=*)
      uuid=${spec#UUID=}
      check_store_volume "${uuid}" "${fstab} mounts at ${nix_root}"
      ;;
    *) die "${fstab} mounts ${spec} at ${nix_root}, which this installer did not create" ;;
  esac
}

# Makes the chosen volume, or the one to be made, the one fstab mounts at
# /nix. created says whether this run made it.
setup_volume() {
  created=no
  if [ -z "${uuid}" ]; then
    create_volume
  fi
  check_uuid "${uuid}"
  if [ -z "${spec}" ]; then
    say "Adding ${nix_root} to ${fstab}"
    edit_fstab add "$(fstab_line "${uuid}")"
  fi
}

# The new volume is the one addVolume reports, as upstream's installer reads
# it, since another volume with the same name may exist elsewhere.
create_volume() {
  say "Creating the ${volume_fs} volume '${volume_label}' in ${container}"
  output=$(as_root "${diskutil}" apfs addVolume "${container}" "${volume_fs}" "${volume_label}" -nomount) \
    || die "could not create the volume '${volume_label}'"
  printf '%s\n' "${output}" >&2
  device=$(printf '%s\n' "${output}" | awk '/^Created new APFS Volume / { print $5; exit }')
  case ${device} in
    disk[0-9]*s[0-9]*) ;;
    *) die "diskutil did not say which volume it created" ;;
  esac
  uuid=$(volume_field "${device}" VolumeUUID) || die "could not find the volume ${device} just created"
  made_uuid=${uuid}
  is_store_volume "${uuid}" || die "the volume ${device} just created is not '${volume_label}' in ${container}"
  created=yes
  # Upstream's installer encrypts its volume when FileVault is on.
  if "${fdesetup}" isactive >/dev/null 2>&1; then
    warn "FileVault is on, but the volume '${volume_label}' is not encrypted"
  fi
}

# Dies unless volume $1 is this user's store, or, when $2 is "recorded",
# root's and holding no one's entries, setting claim as check_store_owner
# does. A volume not mounted is mounted for a moment on a mount point of
# root's to look. Ownership must be on for its owner to be known.
check_volume_owner() {
  mounted=$(volume_field "$1" MountPoint) || mounted=
  if [ -z "${mounted}" ]; then
    look=$(as_root "${mktemp}" -d "${look_parent}/nova-nix-volume.XXXXXX") \
      || die "could not make a mount point to look at the volume $1"
    as_root "${diskutil}" mount -mountPoint "${look}" "$1" >&2 \
      || die "could not mount the volume $1 to see whose it is"
    mounted=${look}
  fi
  if [ "$(volume_field "$1" GlobalPermissionsEnabled)" != true ]; then
    die "ownership is off on the volume $1, so whose store it holds cannot be told; leaving it in place"
  fi
  check_store_owner "${mounted}" "${2:-}" "$1"
  if [ -n "${look}" ]; then
    as_root "${diskutil}" unmount "${look}" >&2 || die "could not unmount ${look}"
    as_root "${rmdir}" "${look}" || warn "could not remove ${look}"
    look=
  fi
}

# Mounts the volume at /nix and gives its root to this user when this run
# made it or check_volume_owner found it unclaimed.
mount_volume() {
  if [ "$(volume_field "${nix_root}" VolumeUUID)" != "${uuid}" ]; then
    elsewhere=$(volume_field "${uuid}" MountPoint) || elsewhere=
    if [ -n "${elsewhere}" ]; then
      as_root "${diskutil}" unmount "${uuid}" >&2 || die "could not unmount '${volume_label}' from ${elsewhere}"
    fi
    say "Mounting '${volume_label}' at ${nix_root}"
    as_root "${diskutil}" mount -mountPoint "${nix_root}" "${uuid}" >&2 || die "could not mount '${volume_label}' at ${nix_root}"
  fi
  if [ "${created}" = yes ] && [ "$(volume_field "${nix_root}" GlobalPermissionsEnabled)" = false ]; then
    as_root "${diskutil}" enableOwnership "${nix_root}" >&2 || die "could not turn on ownership for ${nix_root}"
  fi
  if [ "${created}" = yes ] || [ "${claim}" = yes ]; then
    as_root "${chown}" "$(id -u):$(id -g)" "${nix_root}" || die "could not give ${nix_root} to $(id -un)"
  fi
}

daemon_loaded() { "${launchctl}" print "system/${daemon_label}" >/dev/null 2>&1; }

# The LaunchDaemon that mounts volume $uuid at /nix at boot.
daemon_content() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${daemon_label}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>ProgramArguments</key>
  <array>
    <string>${diskutil}</string>
    <string>mount</string>
    <string>-mountPoint</string>
    <string>${nix_root}</string>
    <string>${uuid}</string>
  </array>
</dict>
</plist>
EOF
}

# Whether the installed LaunchDaemon is the one daemon_content writes for
# $uuid, so one left naming a volume since replaced is rewritten.
daemon_current() {
  [ -f "${daemon_plist}" ] && daemon_content | cmp -s - "${daemon_plist}"
}

# The volume UUID the installed LaunchDaemon mounts.
daemon_volume() {
  "${plutil}" -extract ProgramArguments.4 raw -o - "${daemon_plist}"
}

# Written after the first mount, which this script makes itself, so the
# LaunchDaemon's own mount at load finds the volume mounted rather than
# racing it. The plist goes to root through stdin, as upstream's does.
setup_daemon() {
  if ! daemon_current; then
    if daemon_loaded; then
      as_root "${launchctl}" bootout "system/${daemon_label}" || die "could not unload ${daemon_label}"
    fi
    say "Writing the LaunchDaemon ${daemon_plist}, which mounts ${nix_root} at boot"
    daemon_content | as_root "${tee}" "${daemon_plist}" >/dev/null || die "could not write ${daemon_plist}"
    as_root "${chmod}" 0644 "${daemon_plist}" || die "could not set the mode of ${daemon_plist}"
    as_root "${chown}" root:wheel "${daemon_plist}" || die "could not give ${daemon_plist} to root"
    daemon_current || die "${daemon_plist} does not hold what was written to it"
  fi
  if ! daemon_loaded; then
    as_root "${launchctl}" bootstrap system "${daemon_plist}" || die "could not load ${daemon_plist}"
  fi
}

# Whether /nix is as an earlier run set it up: this installer's volume,
# mounted there, with the LaunchDaemon that mounts it at boot naming it. A
# run that stopped partway, or a volume made again since, leaves something
# the setup steps finish, each skipping what is done.
macos_store_ready() {
  if [ ! -d "${nix_root}" ] || [ ! -w "${nix_root}" ]; then
    return 1
  fi
  case ${spec} in
    UUID=*) uuid=${spec#UUID=} ;;
    *) return 1 ;;
  esac
  is_store_volume "${uuid}" && [ "$(volume_field "${nix_root}" VolumeUUID)" = "${uuid}" ] \
    && daemon_current && daemon_loaded
}

# Prints "recorded" when this installer's fstab line or LaunchDaemon names
# volume $1, and nothing otherwise.
volume_record() {
  if [ "${spec}" = "UUID=$1" ]; then
    echo recorded
  elif [ -f "${daemon_plist}" ] && [ "$(daemon_volume)" = "$1" ]; then
    echo recorded
  fi
}

# Dies when another volume than the chosen one, which is empty when one is
# to be made, is mounted at /nix or named by the LaunchDaemon, so that
# neither is mounted over or rewritten. A LaunchDaemon naming a volume that
# no longer exists is left for setup_daemon to write again.
check_nix_mounts_nothing_else() {
  at_nix=$(volume_field "${nix_root}" VolumeUUID) || at_nix=
  if [ -n "${at_nix}" ] && [ "${at_nix}" != "${uuid}" ]; then
    die "the volume ${at_nix} is mounted at ${nix_root}, and it is not this installer's store; leaving it in place"
  fi
  if [ -f "${daemon_plist}" ]; then
    named=$(daemon_volume) || die "could not read ${daemon_plist}"
    if [ "${named}" != "${uuid}" ] && volume_field "${named}" VolumeName >/dev/null; then
      die "${daemon_plist} mounts the volume ${named} at ${nix_root}, not this installer's store; leaving it in place"
    fi
  fi
}

setup_store_macos() {
  if [ -L "${nix_root}" ]; then
    die "${nix_root} is a symbolic link; remove it, and any line for it in ${synthetic_conf}, restart, then run this again"
  fi
  container=$(volume_field / APFSContainerReference) || die "could not find the APFS container of /"
  spec=$(fstab_nix_spec)
  # A /nix set up some other way, with no line in fstab, is used as it is.
  if [ -z "${spec}" ] && [ -d "${nix_root}" ] && [ -w "${nix_root}" ]; then
    check_store_owner "${nix_root}"
    check_store_writable
    return 0
  fi
  if macos_store_ready; then
    check_store_owner "${nix_root}"
    check_store_writable
    return 0
  fi
  say "Setting up ${nix_root} on an APFS volume of its own; this needs root"
  choose_volume
  check_nix_mounts_nothing_else
  claim=no
  if [ -n "${uuid}" ]; then
    check_volume_owner "${uuid}" "$(volume_record "${uuid}")"
  fi
  setup_synthetic
  setup_volume
  mount_volume
  setup_daemon
  check_store_owner "${nix_root}"
  check_store_writable
}

# Sets uuids to the volumes this installer recorded for /nix, in its fstab
# line and its LaunchDaemon, that still exist, and dies unless each is one it
# created that holds this user's store or none. No volume is found by its
# name: one this installer has no record of may be a copy on another disk,
# or hold someone's data. Each is deleted by its UUID, which names one
# volume for good, where a device name such as disk3s7 is given again to
# another volume once this one is gone.
find_store_volume_macos() {
  container=$(volume_field / APFSContainerReference) || die "could not find the APFS container of /"
  recorded=
  spec=$(fstab_nix_spec)
  case ${spec} in
    '') ;;
    UUID=*) recorded=${spec#UUID=} ;;
    *) die "${fstab} mounts ${spec} at ${nix_root}, which this installer did not create; leaving everything in place" ;;
  esac
  if [ -f "${daemon_plist}" ]; then
    daemon_uuid=$(daemon_volume) || die "could not read ${daemon_plist}"
    if [ "${daemon_uuid}" != "${recorded}" ]; then
      recorded="${recorded} ${daemon_uuid}"
    fi
  fi
  uuids=
  for recorded_uuid in ${recorded}; do
    check_uuid "${recorded_uuid}"
    if volume_field "${recorded_uuid}" VolumeName >/dev/null; then
      check_store_volume "${recorded_uuid}" "the record for ${nix_root} names"
      check_volume_owner "${recorded_uuid}" recorded
      uuids="${uuids} ${recorded_uuid}"
    fi
  done
}

remove_store_macos() {
  found=no
  if daemon_loaded; then
    as_root "${launchctl}" bootout "system/${daemon_label}" || die "could not unload ${daemon_label}"
  fi
  if [ -f "${daemon_plist}" ]; then
    as_root "${rm}" "${daemon_plist}" || die "could not remove ${daemon_plist}"
    say "Removed ${daemon_plist}"
    found=yes
  fi
  for volume in ${uuids}; do
    mounted=$(volume_field "${volume}" MountPoint) || mounted=
    if [ -n "${mounted}" ]; then
      as_root "${diskutil}" unmount force "${mounted}" >&2 || die "could not unmount ${mounted}"
    fi
    as_root "${diskutil}" apfs deleteVolume "${volume}" >&2 || die "could not delete the volume ${volume}"
    say "Deleted the volume '${volume_label}' (${volume}), and the store in it"
    found=yes
  done
  case ${spec} in
    UUID=*)
      line=$(fstab_line "${spec#UUID=}")
      if grep -qxF -e "${line}" "${fstab}"; then
        edit_fstab remove "${line}"
        if [ ! -s "${fstab}" ]; then
          as_root "${rm}" "${fstab}" || die "could not remove the empty ${fstab}"
        fi
        found=yes
      fi
      ;;
  esac
  if [ "${found}" = yes ]; then
    remove_line_as_root "${synthetic_conf}" "${synthetic_line}"
    say "macOS removes the empty ${nix_root} at the next restart"
  else
    say "Found no store this installer set up"
  fi
  unrecorded=$(labeled_volumes) || exit 1
  if [ -n "${unrecorded}" ]; then
    say "A volume named '${volume_label}' in ${container} has no record from this installer, so it is left in place: ${unrecorded}"
  fi
}

# ---------------------------------------------------------------------------
# Install and uninstall
# ---------------------------------------------------------------------------

make_scratch() {
  scratch=$(mktemp -d "${HOME}/${install_dir}.XXXXXX") || die "could not create a directory in ${HOME}"
}

# Sets up the store where nova-nix looks for it, unless upstream Nix manages
# it there, which is left alone.
setup_store() {
  if upstream_present; then
    upstream_warning
    return 0
  fi
  case ${os} in
    linux) setup_store_linux ;;
    macos) setup_store_macos ;;
  esac
}

install_nova_nix() {
  check_root
  make_scratch
  fetch_release
  verify
  unpack
  setup_store
  place
  add_path_lines
  say "${reported} is installed in ${root}."
  say "Open a new shell to use it, or run: export PATH=\"${root}/bin:\${PATH}\""
}

# Everything that can refuse runs before anything is removed, so a refusal
# leaves the install as it was.
uninstall_nova_nix() {
  if { [ -e "${root}" ] || [ -L "${root}" ]; } && ! is_install "${root}"; then
    die "${root} does not hold a nova-nix install; leaving it in place"
  fi
  if [ "${remove_store}" = yes ]; then
    if upstream_present; then
      die "upstream Nix manages ${store} on this machine; leaving everything in place"
    fi
    case ${os} in
      linux) check_store_removable_linux ;;
      macos) find_store_volume_macos ;;
    esac
  fi
  make_scratch
  remove_path_lines
  if [ -e "${root}" ]; then
    rm -rf "${root}" || die "could not remove ${root}"
    say "Removed ${root}"
  else
    say "nova-nix is not installed in ${root}"
  fi
  case ${remove_store}-${os} in
    yes-linux) remove_store_linux ;;
    yes-macos) remove_store_macos ;;
    *)
      if [ -d "${store}" ]; then
        say "The store in ${store} is kept; --uninstall --remove-store removes it"
      fi
      ;;
  esac
}

main() {
  scratch=
  previous=
  look=
  made_uuid=
  # From the start, so that what a run sets up, a mount to look at a volume
  # among it, is undone when the run exits or is stopped by HUP, INT, QUIT
  # or TERM. A KILL runs no trap.
  trap cleanup EXIT
  trap 'exit 1' HUP INT QUIT TERM
  version=
  from=
  mode=install
  remove_store=no
  while [ "$#" -gt 0 ]; do
    case $1 in
      --version | --version=*)
        if [ "$1" = --version ]; then
          [ "$#" -ge 2 ] || usage_error "--version needs a release, such as 0.10.0.0"
          version=$2
          shift
        else
          version=${1#--version=}
        fi
        shift
        [ -n "${version}" ] || usage_error "--version needs a release, such as 0.10.0.0"
        ;;
      --from | --from=*)
        if [ "$1" = --from ]; then
          [ "$#" -ge 2 ] || usage_error "--from needs a directory"
          from=$2
          shift
        else
          from=${1#--from=}
        fi
        shift
        [ -n "${from}" ] || usage_error "--from needs a directory"
        ;;
      --uninstall)
        [ "${mode}" != store ] || usage_error "--store-only and --uninstall cannot be used together"
        mode=uninstall
        shift
        ;;
      --store-only)
        [ "${mode}" != uninstall ] || usage_error "--store-only and --uninstall cannot be used together"
        mode=store
        shift
        ;;
      --remove-store)
        remove_store=yes
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) usage_error "unknown argument: $1" ;;
    esac
  done
  if [ "${version}" = latest ]; then
    version=
  fi
  if [ -n "${version}" ]; then
    is_release "${version}" || usage_error "--version must name a release, such as 0.10.0.0, or be latest"
    version=${version#v}
  fi
  if [ -n "${from}" ] && [ -n "${version}" ]; then
    usage_error "--from and --version cannot be used together"
  fi
  if [ "${mode}" = uninstall ] && { [ -n "${from}" ] || [ -n "${version}" ]; }; then
    usage_error "--uninstall takes no --version or --from"
  fi
  if [ "${mode}" = store ] && { [ -n "${from}" ] || [ -n "${version}" ]; }; then
    usage_error "--store-only takes no --version or --from"
  fi
  if [ "${remove_store}" = yes ] && [ "${mode}" != uninstall ]; then
    usage_error "--remove-store goes with --uninstall"
  fi
  if [ -z "${HOME:-}" ] || [ ! -d "${HOME}" ]; then
    die "HOME is not set to a directory"
  fi
  root=${HOME}/${install_dir}

  detect_platform
  # Run through sudo with the caller's HOME, the install, its PATH lines and
  # /nix would all be root's, in a home that is not.
  if [ "$(owner_of "${HOME}")" != "$(id -u)" ]; then
    die "$(id -un) does not own HOME, ${HOME}; run the installer as the user it is for, without sudo"
  fi
  case ${mode} in
    install) install_nova_nix ;;
    store) setup_store ;;
    uninstall) uninstall_nova_nix ;;
  esac
}

main "$@"
