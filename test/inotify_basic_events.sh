#!/bin/sh
#
# Copyright (c) 2026 Enrico M. Crisostomo
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
# details.
#
# You should have received a copy of the GNU General Public License along with
# this program.  If not, see <http://www.gnu.org/licenses/>.

set -eu

if [ "$#" -gt 1 ]; then
  echo "usage: $0 [FSWATCH]" >&2
  exit 2
fi

FSWATCH=${1:-${FSWATCH:-}}
if [ -z "${FSWATCH}" ]; then
  echo "FSWATCH is required" >&2
  exit 2
fi

TMPDIR=${TMPDIR:-/tmp}
WORKDIR=$(mktemp -d "${TMPDIR%/}/fswatch-inotify-basic.XXXXXX")
PID=

cleanup() {
  if [ -n "${PID}" ]; then
    kill "${PID}" 2>/dev/null || true
    wait "${PID}" 2>/dev/null || true
  fi

  rm -rf "${WORKDIR}"
}

trap cleanup EXIT INT TERM

TESTDIR="${WORKDIR}/watched"
OUTSIDE_IN="${WORKDIR}/outside-in"
OUTSIDE_OUT="${WORKDIR}/outside-out"
SYMLINK_TARGET="${WORKDIR}/symlink-target"
SYMLINK_ROOT="${WORKDIR}/watched-link"
mkdir "${TESTDIR}" "${OUTSIDE_IN}" "${OUTSIDE_OUT}" "${SYMLINK_TARGET}"
ln -s "${SYMLINK_TARGET}" "${SYMLINK_ROOT}"

"${FSWATCH}" -m inotify_monitor -r --format '%p|%f|%c' \
  "${TESTDIR}" "${SYMLINK_ROOT}" \
  > "${WORKDIR}/out.log" 2> "${WORKDIR}/err.log" &
PID=$!

sleep 1

CREATE_FILE="${TESTDIR}/created.txt"
MOVE_IN_SOURCE="${OUTSIDE_IN}/move-in.txt"
MOVE_IN_TARGET="${TESTDIR}/move-in.txt"
DIR_MOVE_IN_SOURCE="${OUTSIDE_IN}/move-in-dir"
DIR_MOVE_IN_TARGET="${TESTDIR}/move-in-dir"
MOVE_OUT_SOURCE="${TESTDIR}/move-out.txt"
MOVE_OUT_TARGET="${OUTSIDE_OUT}/move-out.txt"
MOVE_SOURCE="${TESTDIR}/paired-from.txt"
MOVE_TARGET="${TESTDIR}/paired-to.txt"
REPLACEMENT_SOURCE="${TESTDIR}/replacement-source.txt"
REPLACEMENT_TARGET="${TESTDIR}/replacement-target.txt"
SYMLINK_SOURCE="${OUTSIDE_IN}/symlink-in.txt"
SYMLINK_DESTINATION="${SYMLINK_TARGET}/symlink-in.txt"
DELETE_FILE="${TESTDIR}/delete-me.txt"

echo created > "${CREATE_FILE}"
echo update >> "${CREATE_FILE}"
echo move-in > "${MOVE_IN_SOURCE}"
mv "${MOVE_IN_SOURCE}" "${MOVE_IN_TARGET}"
mkdir "${DIR_MOVE_IN_SOURCE}"
mv "${DIR_MOVE_IN_SOURCE}" "${DIR_MOVE_IN_TARGET}"
echo move-out > "${MOVE_OUT_SOURCE}"
mv "${MOVE_OUT_SOURCE}" "${MOVE_OUT_TARGET}"
echo move > "${MOVE_SOURCE}"
mv "${MOVE_SOURCE}" "${MOVE_TARGET}"
echo original > "${REPLACEMENT_TARGET}"
echo replacement > "${REPLACEMENT_SOURCE}"
mv -f "${REPLACEMENT_SOURCE}" "${REPLACEMENT_TARGET}"
echo symlink > "${SYMLINK_SOURCE}"
mv "${SYMLINK_SOURCE}" "${SYMLINK_DESTINATION}"
echo delete > "${DELETE_FILE}"
rm "${DELETE_FILE}"

assert_event() {
  pattern=$1
  description=$2
  found=
  attempt=0

  while [ "${attempt}" -lt 8 ]; do
    if grep -Eq "${pattern}" "${WORKDIR}/out.log"; then
      found=1
      break
    fi

    attempt=$((attempt + 1))
    sleep 1
  done

  if [ -z "${found}" ]; then
    echo "missing inotify event: ${description}" >&2
    echo "--- fswatch output ---" >&2
    sed -n '1,160p' "${WORKDIR}/out.log" >&2
    echo "--- fswatch stderr ---" >&2
    sed -n '1,80p' "${WORKDIR}/err.log" >&2
    exit 1
  fi
}

assert_event 'created\.txt\|.*Created' 'file creation'
assert_event 'created\.txt\|.*(Updated|CloseWrite)' 'file update'
assert_event '/watched/move-in\.txt\|.*MovedTo.*\|[1-9][0-9]*$' 'one-sided move-in'
assert_event '/watched/move-in-dir\|.*MovedTo.*\|[1-9][0-9]*$' 'one-sided directory move-in'
assert_event '/watched/move-out\.txt\|.*MovedFrom.*\|[1-9][0-9]*$' 'one-sided move-out'
assert_event '/watched/paired-from\.txt\|.*MovedFrom.*\|[1-9][0-9]*$' 'paired rename source'
assert_event '/watched/paired-to\.txt\|.*MovedTo.*\|[1-9][0-9]*$' 'paired rename target'
assert_event '/watched/replacement-source\.txt\|.*MovedFrom.*\|[1-9][0-9]*$' 'replacement-by-rename source'
assert_event '/watched/replacement-target\.txt\|.*MovedTo.*\|[1-9][0-9]*$' 'replacement-by-rename target'
assert_event '/watched-link/symlink-in\.txt\|.*MovedTo.*\|[1-9][0-9]*$' 'symlinked watch root'
assert_event 'delete-me\.txt\|.*Removed' 'file deletion'

if ! awk -F '|' '
  $1 ~ /\/watched\/move-in-dir$/ &&
  $2 ~ /(^| )MovedTo( |$)/ &&
  $2 ~ /(^| )IsDir( |$)/ &&
  $3 ~ /^[1-9][0-9]*$/ { found = 1 }
  END { exit !found }
' "${WORKDIR}/out.log"; then
  echo "missing complete one-sided directory move-in event" >&2
  sed -n '1,160p' "${WORKDIR}/out.log" >&2
  exit 1
fi

PAIRED_FROM_COOKIE=$(awk -F '|' '/\/watched\/paired-from\.txt\|.*MovedFrom/ { print $3; exit }' "${WORKDIR}/out.log")
PAIRED_TO_COOKIE=$(awk -F '|' '/\/watched\/paired-to\.txt\|.*MovedTo/ { print $3; exit }' "${WORKDIR}/out.log")
REPLACEMENT_FROM_COOKIE=$(awk -F '|' '/\/watched\/replacement-source\.txt\|.*MovedFrom/ { print $3; exit }' "${WORKDIR}/out.log")
REPLACEMENT_TO_COOKIE=$(awk -F '|' '/\/watched\/replacement-target\.txt\|.*MovedTo/ { print $3; exit }' "${WORKDIR}/out.log")

if [ -z "${PAIRED_FROM_COOKIE}" ] ||
   [ "${PAIRED_FROM_COOKIE}" = 0 ] ||
   [ "${PAIRED_FROM_COOKIE}" != "${PAIRED_TO_COOKIE}" ]; then
  echo "inotify rename cookies do not match: from=${PAIRED_FROM_COOKIE}, to=${PAIRED_TO_COOKIE}" >&2
  sed -n '1,160p' "${WORKDIR}/out.log" >&2
  exit 1
fi

if [ -z "${REPLACEMENT_FROM_COOKIE}" ] ||
   [ "${REPLACEMENT_FROM_COOKIE}" = 0 ] ||
   [ "${REPLACEMENT_FROM_COOKIE}" != "${REPLACEMENT_TO_COOKIE}" ]; then
  echo "inotify replacement cookies do not match: from=${REPLACEMENT_FROM_COOKIE}, to=${REPLACEMENT_TO_COOKIE}" >&2
  sed -n '1,160p' "${WORKDIR}/out.log" >&2
  exit 1
fi
