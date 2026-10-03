#!/bin/sh

REDUCO_BIN=${REDUCO_BIN:-./reduco}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/reduco-test.XXXXXX") || exit 1
HOLDER=
PIDS=
cleanup() {
	[ -n "$HOLDER" ] && kill "$HOLDER" 2> /dev/null
	[ -n "$PIDS" ] && kill -KILL $PIDS 2> /dev/null
	rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

HOME=$TMP/home
STORE=$TMP/store
HOST=$(uname -n)
mkdir "$HOME" || exit 1
export HOME
unset REDUCO_DIR

${CC:-cc} -std=c99 -D_POSIX_C_SOURCE=200809L -o "$TMP/testlock" "${TESTLOCK_SRC:-testlock.c}" || exit 1

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

newstore() {
	rm -rf "$STORE"
	mkdir -m 700 "$STORE"
}

mkrec() {
	_name=$1
	_cwd=$2
	shift 2
	_dir=$STORE/$_name@$HOST
	mkdir -p "$_dir" &&
	printf '%s' "$_cwd" > "$_dir/cwd" &&
	: > "$_dir/lock" &&
	for _a in "$@"; do printf '%s\0' "$_a"; done > "$_dir/argv"
}

hold() {
	rm -f "$TMP/fifo"
	mkfifo "$TMP/fifo" || return 1
	"$TMP/testlock" "$1" > "$TMP/fifo" &
	HOLDER=$!
	read -r _ < "$TMP/fifo"
}

release() {
	kill "$HOLDER" 2> /dev/null
	wait "$HOLDER" 2> /dev/null
	HOLDER=
}

physical() {
	(cd -P "$1" && pwd -P)
}

waitfile() {
	_i=0
	while [ ! -s "$1" ]; do
		_i=$((_i + 1))
		[ $_i -gt 100 ] && return 1
		sleep 0.1
	done
}

start_guard() {
	rm -f "$TMP/childpid"
	"$REDUCO_BIN" -d "$STORE" -r "$1" > /dev/null 2> "$TMP/gerr" &
	GUARD=$!
	waitfile "$TMP/childpid" || return 1
	CHILD=$(cat "$TMP/childpid")
	PIDS="$GUARD $CHILD"
}

mkloop() {
	mkrec "$1" "$2" sh -c 'echo $$ > "$1"; exec sleep 30' sh "$TMP/childpid"
}

reap() {
	wait "$GUARD" 2> /dev/null
	GUARD_RC=$?
	PIDS=
}

state_of() {
	"$REDUCO_BIN" -d "$STORE" | awk -F'	' -v n="$1" '$2 == n { print $1 "\t" $3 }'
}

mode_of() {
	ls -ld "$1" | cut -c1-10
}

empty_list() {
	newstore
	"$REDUCO_BIN" -d "$STORE" > "$TMP/out" 2> "$TMP/err" &&
	[ ! -s "$TMP/out" ] &&
	[ ! -s "$TMP/err" ]
}

creates_store() {
	rm -rf "$TMP/fresh"
	"$REDUCO_BIN" -d "$TMP/fresh" > /dev/null &&
	[ "$(mode_of "$TMP/fresh")" = "drwx------" ]
}

env_dir() {
	newstore
	mkrec a /x true
	rm -rf "$TMP/other"
	mkdir -m 700 "$TMP/other"
	REDUCO_DIR=$STORE "$REDUCO_BIN" | grep -q "^dead	a	" &&
	[ -z "$(REDUCO_DIR=$STORE "$REDUCO_BIN" -d "$TMP/other")" ]
}

home_dir() {
	rm -rf "$HOME/.reduco"
	"$REDUCO_BIN" > /dev/null &&
	[ "$(mode_of "$HOME/.reduco")" = "drwx------" ]
}

loose_dir_refused() {
	newstore
	chmod 770 "$STORE"
	! "$REDUCO_BIN" -d "$STORE" > "$TMP/out" 2> "$TMP/err" &&
	[ ! -s "$TMP/out" ] &&
	grep -q 'writable by group or others' "$TMP/err"
}

file_dir_refused() {
	: > "$TMP/file"
	! "$REDUCO_BIN" -d "$TMP/file" > /dev/null 2> "$TMP/err" &&
	grep -q 'not a directory' "$TMP/err"
}

lists_dead() {
	newstore
	mkrec mail /home/u neomutt
	mkrec build /home/u/proj make -j8 watch
	printf 'SIGTERM\n' > "$STORE/mail@$HOST/died"
	printf 'dead\tbuild\t-\t/home/u/proj\tmake -j8 watch\ndead\tmail\tSIGTERM\t/home/u\tneomutt\n' > "$TMP/want"
	"$REDUCO_BIN" -d "$STORE" > "$TMP/out" 2> "$TMP/err" &&
	cmp -s "$TMP/want" "$TMP/out" &&
	[ ! -s "$TMP/err" ]
}

lists_alive() {
	newstore
	mkrec busy /srv sleep 60
	hold "$STORE/busy@$HOST/lock" || return 1
	printf 'alive\tbusy\t%s\t/srv\tsleep 60\n' "$HOLDER" > "$TMP/want"
	"$REDUCO_BIN" -d "$STORE" > "$TMP/out" 2> "$TMP/err"
	_rc=$?
	release
	[ $_rc -eq 0 ] && cmp -s "$TMP/want" "$TMP/out"
}

skips_foreign() {
	newstore
	mkrec mine /x true
	mkdir "$STORE/theirs@not-$HOST" "$STORE/.tmp@$HOST.abc123" "$STORE/plain"
	: > "$STORE/file@$HOST"
	"$REDUCO_BIN" -d "$STORE" > "$TMP/out" 2> "$TMP/err" &&
	[ "$(wc -l < "$TMP/out")" -eq 1 ] &&
	grep -q '^dead	mine	' "$TMP/out" &&
	[ ! -s "$TMP/err" ]
}

skips_bad_record() {
	newstore
	mkrec good /x true
	mkrec empty /x true
	: > "$STORE/empty@$HOST/argv"
	mkrec nocwd /x true
	rm "$STORE/nocwd@$HOST/cwd"
	"$REDUCO_BIN" -d "$STORE" > "$TMP/out" 2> "$TMP/err" &&
	[ "$(wc -l < "$TMP/out")" -eq 1 ] &&
	grep -q '^dead	good	' "$TMP/out" &&
	grep -q 'empty: argv is empty' "$TMP/err" &&
	grep -q 'nocwd: cwd:' "$TMP/err"
}

list_one_line_per_record() {
	newstore
	_nl=$(printf 'a\nb')
	_tab=$(printf 'c\td')
	mkrec odd "$_tab" echo "$_nl" "$_tab"
	"$REDUCO_BIN" -d "$STORE" > "$TMP/out" &&
	[ "$(wc -l < "$TMP/out")" -eq 1 ] &&
	awk -F'	' 'NF != 5 { exit 1 }' "$TMP/out"
}

list_tolerates_cwd_newline() {
	newstore
	mkrec nl /x true
	printf '/x\n' > "$STORE/nl@$HOST/cwd"
	"$REDUCO_BIN" -d "$STORE" | awk -F'	' '$4 != "/x" { exit 1 }'
}

print_roundtrip() {
	newstore
	_cwd="$TMP/it's a dir"
	mkdir -p "$_cwd"
	_nl=$(printf 'line1\nline2')
	_script='pwd; printf "%s\0" "$@"'
	mkrec rt "$_cwd" sh -c "$_script" sh "a b" "it's" "" "$_nl" '$HOME' '"q"' -x '*'
	"$REDUCO_BIN" -d "$STORE" -p rt > "$TMP/line" 2> "$TMP/err" || return 1
	[ ! -s "$TMP/err" ] || return 1
	sh "$TMP/line" > "$TMP/got" || return 1
	(cd "$_cwd" && sh -c "$_script" sh "a b" "it's" "" "$_nl" '$HOME' '"q"' -x '*') > "$TMP/want" &&
	cmp -s "$TMP/want" "$TMP/got"
}

print_missing() {
	newstore
	! "$REDUCO_BIN" -d "$STORE" -p nope > "$TMP/out" 2> "$TMP/err" &&
	[ ! -s "$TMP/out" ] &&
	grep -q 'nope: no such record' "$TMP/err"
}

print_bad_record() {
	newstore
	mkrec bad /x true
	: > "$STORE/bad@$HOST/argv"
	! "$REDUCO_BIN" -d "$STORE" -p bad > "$TMP/out" 2> "$TMP/err" &&
	[ ! -s "$TMP/out" ] &&
	grep -q 'bad: argv is empty' "$TMP/err"
}

expunge_dead() {
	newstore
	mkrec gone /x true
	mkrec kept /x true
	mkdir "$STORE/gone@$HOST/env"
	printf 'v' > "$STORE/gone@$HOST/env/EDITOR"
	printf 'SIGHUP\n' > "$STORE/gone@$HOST/died"
	"$REDUCO_BIN" -d "$STORE" -x gone > "$TMP/out" 2> "$TMP/err" &&
	[ ! -e "$STORE/gone@$HOST" ] &&
	[ -d "$STORE/kept@$HOST" ] &&
	[ ! -s "$TMP/out" ] &&
	[ ! -s "$TMP/err" ]
}

expunge_alive_refused() {
	newstore
	mkrec busy /x sleep 60
	hold "$STORE/busy@$HOST/lock" || return 1
	"$REDUCO_BIN" -d "$STORE" -x busy > "$TMP/out" 2> "$TMP/err"
	_rc=$?
	_pid=$HOLDER
	release
	[ $_rc -eq 1 ] &&
	[ -f "$STORE/busy@$HOST/argv" ] &&
	grep -q "busy: alive (pid $_pid)" "$TMP/err"
}

expunge_missing() {
	newstore
	! "$REDUCO_BIN" -d "$STORE" -x nope > "$TMP/out" 2> "$TMP/err" &&
	grep -q 'nope: no such record' "$TMP/err"
}

expunge_without_lock() {
	newstore
	mkrec nolock /x true
	rm "$STORE/nolock@$HOST/lock"
	"$REDUCO_BIN" -d "$STORE" -x nolock &&
	[ ! -e "$STORE/nolock@$HOST" ]
}

invalid_name() {
	newstore
	for _n in '' '.hidden' '..' 'a b' 'a@b' 'a/b' '../x'; do
		"$REDUCO_BIN" -d "$STORE" -p "$_n" > "$TMP/out" 2> "$TMP/err" && return 1
		[ ! -s "$TMP/out" ] || return 1
		grep -q 'invalid name' "$TMP/err" || return 1
		"$REDUCO_BIN" -d "$STORE" -x "$_n" > /dev/null 2>&1 && return 1
	done
	return 0
}

revive_runs() {
	newstore
	_cwd=$(physical "$TMP")
	mkrec r "$_cwd" sh -c 'pwd > "$1"; printf "%s\n" "$2" >> "$1"' sh "$TMP/ran" "a b"
	rm -f "$TMP/ran"
	"$REDUCO_BIN" -d "$STORE" -r r > "$TMP/out" 2> "$TMP/err"
	_rc=$?
	printf '%s\na b\n' "$_cwd" > "$TMP/want"
	[ $_rc -eq 0 ] &&
	cmp -s "$TMP/want" "$TMP/ran" &&
	[ ! -e "$STORE/r@$HOST" ] &&
	[ ! -s "$TMP/err" ]
}

revive_status() {
	newstore
	mkrec r "$TMP" sh -c 'exit 7'
	"$REDUCO_BIN" -d "$STORE" -r r
	[ $? -eq 7 ] && [ ! -e "$STORE/r@$HOST" ]
}

revive_signal_status() {
	newstore
	mkrec r "$TMP" sh -c 'kill -USR1 $$'
	sh -c 'kill -USR1 $$' 2> /dev/null
	_want=$?
	"$REDUCO_BIN" -d "$STORE" -r r 2> /dev/null
	_rc=$?
	[ $_rc -eq $_want ] && [ ! -e "$STORE/r@$HOST" ]
}

revive_missing() {
	newstore
	! "$REDUCO_BIN" -d "$STORE" -r nope > "$TMP/out" 2> "$TMP/err" &&
	[ ! -s "$TMP/out" ] &&
	grep -q 'nope: no such record' "$TMP/err"
}

revive_bad_record() {
	newstore
	mkrec bad "$TMP" true
	: > "$STORE/bad@$HOST/argv"
	! "$REDUCO_BIN" -d "$STORE" -r bad > "$TMP/out" 2> "$TMP/err" &&
	grep -q 'bad: argv is empty' "$TMP/err" &&
	[ -d "$STORE/bad@$HOST" ]
}

revive_alive_refused() {
	newstore
	mkrec busy "$TMP" sh -c 'echo ran > "$1"' sh "$TMP/ran"
	rm -f "$TMP/ran"
	hold "$STORE/busy@$HOST/lock" || return 1
	"$REDUCO_BIN" -d "$STORE" -r busy > "$TMP/out" 2> "$TMP/err"
	_rc=$?
	_pid=$HOLDER
	release
	[ $_rc -eq 1 ] &&
	[ ! -e "$TMP/ran" ] &&
	[ -f "$STORE/busy@$HOST/argv" ] &&
	grep -q "busy: alive (pid $_pid)" "$TMP/err"
}

revive_concurrent() {
	newstore
	rm -f "$TMP/count"
	mkrec c "$TMP" sh -c 'echo run >> "$1"; sleep 1' sh "$TMP/count"
	"$REDUCO_BIN" -d "$STORE" -r c > /dev/null 2>&1 &
	_a=$!
	"$REDUCO_BIN" -d "$STORE" -r c > /dev/null 2>&1 &
	_b=$!
	wait $_a
	_ra=$?
	wait $_b
	_rb=$?
	[ "$(wc -l < "$TMP/count")" -eq 1 ] &&
	[ $((_ra + _rb)) -eq 1 ] &&
	[ ! -e "$STORE/c@$HOST" ]
}

revive_cwd_fallback() {
	newstore
	mkrec lost "$TMP/does/not/exist" sh -c 'pwd > "$1"' sh "$TMP/ran"
	rm -f "$TMP/ran"
	"$REDUCO_BIN" -d "$STORE" -r lost > "$TMP/out" 2> "$TMP/err"
	_rc=$?
	physical "$HOME" > "$TMP/want"
	[ $_rc -eq 0 ] &&
	cmp -s "$TMP/want" "$TMP/ran" &&
	grep -q 'does/not/exist.*using \$HOME' "$TMP/err"
}

revive_cwd_unusable() {
	newstore
	mkrec lost "$TMP/does/not/exist" true
	HOME=$TMP/also/missing "$REDUCO_BIN" -d "$STORE" -r lost > /dev/null 2>&1
	_rc=$?
	[ $_rc -eq 126 ] &&
	[ "$(state_of lost)" = "$(printf 'dead\tchdir: ENOENT')" ]
}

revive_exports() {
	newstore
	mkrec x "$TMP" sh -c 'printf "%s\n%s\n%s\n" "$REDUCO" "$REDUCO_PID" "$PPID" > "$1"' sh "$TMP/ran"
	rm -f "$TMP/ran"
	"$REDUCO_BIN" -d "$STORE" -r x &&
	[ "$(sed -n 1p "$TMP/ran")" = "$STORE/x@$HOST" ] &&
	[ "$(sed -n 2p "$TMP/ran")" = "$(sed -n 3p "$TMP/ran")" ]
}

revive_relative_dir() {
	newstore
	mkrec x "$TMP" sh -c 'printf "%s\n" "$REDUCO" > "$1"' sh "$TMP/ran"
	rm -f "$TMP/ran"
	_bin=$(cd "$(dirname "$REDUCO_BIN")" && pwd -P)/$(basename "$REDUCO_BIN")
	(cd "$TMP" && "$_bin" -d store -r x) &&
	[ "$(cat "$TMP/ran")" = "$(physical "$TMP")/store/x@$HOST" ]
}

revive_clears_died() {
	newstore
	mkrec d "$TMP" sh -c 'test ! -e "$REDUCO/died"'
	printf 'SIGTERM\n' > "$STORE/d@$HOST/died"
	"$REDUCO_BIN" -d "$STORE" -r d &&
	[ ! -e "$STORE/d@$HOST" ]
}

revive_env_overlay() {
	newstore
	mkrec e "$TMP" sh -c 'printf "%s\n%s\n" "$FOO" "$BAR" > "$1"' sh "$TMP/ran"
	mkdir "$STORE/e@$HOST/env"
	printf 'new' > "$STORE/e@$HOST/env/FOO"
	rm -f "$TMP/ran"
	FOO=old BAR=inherited "$REDUCO_BIN" -d "$STORE" -r e &&
	[ "$(sed -n 1p "$TMP/ran")" = new ] &&
	[ "$(sed -n 2p "$TMP/ran")" = inherited ]
}

revive_exec_fails() {
	newstore
	mkrec nx "$TMP" /nonexistent/prog
	"$REDUCO_BIN" -d "$STORE" -r nx > /dev/null 2>&1
	_rc=$?
	[ $_rc -eq 127 ] &&
	[ "$(state_of nx)" = "$(printf 'dead\texec: ENOENT')" ] &&
	[ "$(cat "$STORE/nx@$HOST/died")" = "exec: ENOENT" ]
}

revive_not_executable() {
	newstore
	: > "$TMP/plain"
	chmod 600 "$TMP/plain"
	mkrec ne "$TMP" "$TMP/plain"
	"$REDUCO_BIN" -d "$STORE" -r ne > /dev/null 2>&1
	_rc=$?
	[ $_rc -eq 126 ] &&
	[ "$(state_of ne)" = "$(printf 'dead\texec: EACCES')" ]
}

revive_keep() {
	newstore
	mkrec k "$TMP" true
	: > "$STORE/k@$HOST/keep"
	"$REDUCO_BIN" -d "$STORE" -r k &&
	[ "$(state_of k)" = "$(printf 'dead\t-')" ] &&
	[ ! -e "$STORE/k@$HOST/died" ] &&
	"$REDUCO_BIN" -d "$STORE" -r k &&
	[ -d "$STORE/k@$HOST" ]
}

revive_alive_while_running() {
	newstore
	mkloop l "$TMP"
	start_guard l || return 1
	_st=$(state_of l)
	kill -KILL $PIDS 2> /dev/null
	reap
	[ "$_st" = "$(printf 'alive\t%s' "$GUARD")" ]
}

revive_term_keeps() {
	newstore
	mkloop t "$TMP"
	start_guard t || return 1
	kill -TERM "$GUARD" "$CHILD"
	reap
	[ "$(state_of t)" = "$(printf 'dead\tSIGTERM')" ]
}

revive_hup_keeps() {
	newstore
	mkloop h "$TMP"
	start_guard h || return 1
	kill -HUP "$GUARD" "$CHILD"
	reap
	[ "$(state_of h)" = "$(printf 'dead\tSIGHUP')" ]
}

revive_kill_keeps() {
	newstore
	mkloop k "$TMP"
	start_guard k || return 1
	kill -KILL "$GUARD" "$CHILD"
	reap
	[ "$(state_of k)" = "$(printf 'dead\t-')" ]
}

revive_child_killed_removes() {
	newstore
	mkloop c "$TMP"
	start_guard c || return 1
	kill -TERM "$CHILD"
	reap
	[ $GUARD_RC -eq 143 ] &&
	[ ! -e "$STORE/c@$HOST" ]
}

revive_guard_ignores_int() {
	newstore
	mkloop i "$TMP"
	start_guard i || return 1
	kill -INT "$GUARD"
	sleep 0.3
	_st=$(state_of i)
	kill -KILL "$GUARD" "$CHILD"
	reap
	[ "$_st" = "$(printf 'alive\t%s' "$GUARD")" ]
}

revive_cycle() {
	newstore
	_cwd=$(physical "$TMP")
	mkrec cyc "$_cwd" sh -c 'echo $$ > "$1"; pwd > "$2"; exec sleep 30' sh "$TMP/childpid" "$TMP/cwdseen"
	cp "$STORE/cyc@$HOST/argv" "$TMP/argv.orig"
	for _round in 1 2 3; do
		rm -f "$TMP/cwdseen"
		start_guard cyc || return 1
		[ "$(cat "$TMP/cwdseen")" = "$_cwd" ] || return 1
		kill -KILL "$GUARD" "$CHILD"
		reap
		[ "$(state_of cyc)" = "$(printf 'dead\t-')" ] || return 1
		cmp -s "$TMP/argv.orig" "$STORE/cyc@$HOST/argv" || return 1
		[ "$(cat "$STORE/cyc@$HOST/cwd")" = "$_cwd" ] || return 1
	done
	return 0
}

revive_cycle_ends() {
	newstore
	mkloop e "$TMP"
	start_guard e || return 1
	kill -KILL "$GUARD" "$CHILD"
	reap
	mkrec e "$TMP" true
	"$REDUCO_BIN" -d "$STORE" -r e &&
	[ ! -e "$STORE/e@$HOST" ]
}

check "-v prints version" version_prints
check "unknown option prints usage" usage_fails -Z
check "extra operand prints usage" usage_fails extra
check "-p and -x together print usage" usage_fails -p a -x b
check "-v reports write errors" version_write_error
check "empty store lists nothing" empty_list
check "-d creates the store with mode 0700" creates_store
check "REDUCO_DIR is used and -d overrides it" env_dir
check "default store is under HOME" home_dir
check "group-writable store is refused" loose_dir_refused
check "non-directory store is refused" file_dir_refused
check "dead records are listed sorted" lists_dead
check "alive record shows the guard pid" lists_alive
check "foreign, hidden and non-directory entries are skipped" skips_foreign
check "bad records are warned about and skipped" skips_bad_record
check "control characters keep one line per record" list_one_line_per_record
check "trailing newline in cwd is tolerated" list_tolerates_cwd_newline
check "-p output reproduces argv and cwd" print_roundtrip
check "-p on a missing record fails" print_missing
check "-p on a bad record fails" print_bad_record
check "-x removes a dead record" expunge_dead
check "-x refuses an alive record" expunge_alive_refused
check "-x on a missing record fails" expunge_missing
check "-x removes a record without a lock file" expunge_without_lock
check "invalid names are rejected" invalid_name
check "-r runs the command in the recorded directory and removes the record" revive_runs
check "-r propagates the exit status" revive_status
check "-r re-raises the signal that killed the command" revive_signal_status
check "-r on a missing record fails" revive_missing
check "-r on a bad record fails" revive_bad_record
check "-r refuses an alive record" revive_alive_refused
check "concurrent -r starts the program once" revive_concurrent
check "-r falls back to HOME when the directory is gone" revive_cwd_fallback
check "-r keeps the record when HOME is unusable too" revive_cwd_unusable
check "-r exports REDUCO and REDUCO_PID" revive_exports
check "-r exports an absolute REDUCO for a relative store" revive_relative_dir
check "-r clears a stale died file" revive_clears_died
check "-r overlays env/ on the environment" revive_env_overlay
check "-r keeps the record when exec fails" revive_exec_fails
check "-r reports a non-executable command with 126" revive_not_executable
check "-r keeps a record that has a keep file" revive_keep
check "a revived record is alive while it runs" revive_alive_while_running
check "SIGTERM keeps the record as dead" revive_term_keeps
check "SIGHUP keeps the record as dead" revive_hup_keeps
check "SIGKILL keeps the record without a cause" revive_kill_keeps
check "a command killed alone ends the record" revive_child_killed_removes
check "the guard ignores SIGINT" revive_guard_ignores_int
check "crash and revive repeat with the same argv and cwd" revive_cycle
check "a revived record that ends naturally is removed" revive_cycle_ends

printf '1..%d\n' "$run"
[ "$failed" -eq 0 ]
