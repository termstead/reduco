#!/bin/sh

REDUCO_BIN=${REDUCO_BIN:-./reduco}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/reduco-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

run=0
failed=0

check() {
	desc=$1
	shift
	run=$((run + 1))
	if "$@"; then
		printf 'ok %d - %s\n' "$run" "$desc"
	else
		failed=$((failed + 1))
		printf 'not ok %d - %s\n' "$run" "$desc"
	fi
}

version_prints() {
	"$REDUCO_BIN" -v > "$TMP/out" 2> "$TMP/err" &&
	grep -q '^reduco-' "$TMP/out" &&
	[ $(wc -l < "$TMP/out") -eq 1 ] &&
	[ ! -s "$TMP/err" ]
}

usage_fails() {
	"$REDUCO_BIN" "$@" > "$TMP/out" 2> "$TMP/err"
	[ $? -eq 1 ] &&
	[ ! -s "$TMP/out" ] &&
	grep -q '^usage: reduco' "$TMP/err"
}

version_write_error() {
	[ -w /dev/full ] || return 0
	! "$REDUCO_BIN" -v > /dev/full 2> "$TMP/err" &&
	grep -q '^reduco: write:' "$TMP/err"
}

check "-v prints version" version_prints
check "unknown option prints usage" usage_fails -Z
check "no arguments prints usage" usage_fails
check "-v reports write errors" version_write_error

printf '1..%d\n' "$run"
[ "$failed" -eq 0 ]
