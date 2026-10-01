# reduco — design and plan

> *abdūcō* — "I lead away". *redūcō* — "I lead back".
>
> abduco takes a program away from its terminal.
> reduco brings a program back after its world ended.

Status: **design draft**. Nothing here is implemented yet. Open decisions
are collected in [§11](#11-open-questions).

---

## 1. The question: is a universal revival tool possible?

Yes, with one condition: we have to be precise about what "revival" means.
There are three different things people call session resurrection:

| Level | What comes back | Universally possible? | Whose job |
|---|---|---|---|
| **L0 process image** | memory, open files, sockets, the exact running state | **No.** Needs kernel checkpoint/restore (CRIU on Linux, DMTCP). Linux-only, needs privileges, breaks on ttys, sockets and GPU state. | not ours, a non-goal |
| **L1 recreation** | *the same command, started again in the same place* | **Yes.** Needs only POSIX. | **reduco** |
| **L2 host state** | window layout, scrollback, pane titles, focus | Only the host knows this. | the host (dvtm, tmux, …) |

tmux-resurrect and zellij's session resurrection mostly do **L1**, plus
**L2** for their own host. Their L1 part is welded to the host: they
enumerate *tmux* panes or serialize a *zellij* layout. That coupling is the
thing the termstead split removes:

* abduco: keep a program alive without a terminal (detach/attach)
* dvtm: share one terminal between several programs (tiling)
* **reduco: remember how a program was started, notice when it died
  unnaturally, and start it again on request**

reduco never looks inside a host. Its only interface is the one every host
already has, **"run this command"**. abduco, dtach, dvtm, tmux, screen,
`nohup`, `setsid`, `systemd-run`, cron and a login shell all take a command.
So reduco is universal for the same reason dtach and abduco are: it deals
only with what every program has. For abduco that is a terminal; for reduco
it is a command line and a working directory.

### What makes it hard, and the core idea

Remembering a command line is easy. The hard part is **deciding what
deserves revival**:

* `exit` in the shell, `q` in dvtm → the user meant it. **Don't revive.**
* reboot, power loss, logout with `KillUserProcesses`, OOM, abduco server
  killed → the world ended. **Revive.**

Snapshot tools answer this by **polling**: tmux-continuum saves every N
minutes and assumes whatever was in the last snapshot should come back. That
needs a timer, a daemon or a hook in the host, and the snapshot is always a
little stale.

reduco answers it by **guarding** instead:

1. When a program is started through reduco, its recipe (argv, cwd) is
   written to disk **at once**, and reduco holds a **lock** on it.
2. reduco stays as the program's parent, in the style of `system(3)` or
   `timeout(1)`, and waits.
3. If the program ends **naturally**, reduco deletes the recipe.
4. If the world ends, reduco either sees it (it gets `SIGHUP`/`SIGTERM`)
   and keeps the recipe, or it gets no chance at all (`SIGKILL`, power loss)
   and the recipe stays anyway.
5. The kernel releases the lock when reduco dies, however it dies.

That gives a simple invariant:

> **A recipe whose lock nobody holds is a program that did not end on
> purpose.** That is exactly the set of things to revive.

Nothing to poll, no daemon, no snapshot, no `/proc`, no boot IDs. The
on-disk state is always current because it is written once at start and
removed only on a natural end.

---

## 2. Principles

* **One job.** Record, guard, revive. No detaching, no terminals, no
  layouts, no scheduling, no auto-restart.
* **Host-agnostic.** reduco never knows if it runs under abduco, dvtm,
  tmux, cron or nothing. No host gets special code.
* **Foreground only.** reduco never daemonizes. Revival runs in the
  foreground, and *where* it runs (detached session, window, service) is
  the caller's choice, made by composition.
* **The filesystem is the database.** A record is a directory of small
  files that `cat`, `ls`, `rm` and shell hooks can read and write, in the
  spirit of daemontools' `envdir` and runit's service directories.
* **POSIX.1-2008, C99, one file**, built and laid out like abduco and dvtm
  (`reduco.c`, `config.def.h`, `Makefile`, `reduco.1`, `testsuite.sh`).
* **Fail toward keeping.** When in doubt, keep the record. An extra line in
  a listing costs little; a lost session costs a lot.

---

## 3. Interface

Modelled on abduco: one binary, a mode letter, a name.

```
reduco [-d dir]                                          list records
reduco [-d dir] [-k] [-f] [-e var]... [-E] -c name command [arg ...]
                                                         create a record, run command guarded
reduco [-d dir] -r name                                  revive a dead record, guarded, in the foreground
reduco [-d dir] -p name                                  print a record as a sh(1) command line
reduco [-d dir] -x name                                  forget (delete) a dead record
reduco -v                                                version
```

| Flag | Meaning |
|---|---|
| `-c name` | **create**: write a record for `command`, then run it guarded |
| `-r name` | **revive**: lock a dead record, restore cwd and env, run it guarded |
| `-p name` | **print**: emit `cd '…' && exec env '…' 'cmd' 'arg'`, so a record can be revived without reduco, inspected, or wrapped some other way |
| `-x name` | **expunge**: delete a dead record (refuses a live one) |
| `-d dir` | record directory (default: see §4) |
| `-k` | **keep**: keep the record even on a natural end, so the program comes back every time it is revived (a "favourite") |
| `-f` | **force**: with `-c`, replace a *dead* record of the same name. A live one is never replaced. |
| `-e var` | capture the current value of `var` into the record (repeatable) |
| `-E` | capture the whole environment (see §6.4 for why this is not the default) |

Names are limited to `[A-Za-z0-9._-]`, so listings stay safe to parse.

### 3.1 Listing format

`reduco` with no mode lists this host's records, one per line,
tab-separated, ready for `awk` and `cut`:

```
STATE   NAME    INFO     CWD             COMMAND
alive   work    4711     /home/u/src     dvtm -m ^a
dead    mail    SIGTERM  /home/u         neomutt
dead    build   -        /home/u/proj    make -j8 watch
```

* `alive`: INFO is the guard's PID (read back from the lock with `F_GETLK`).
* `dead`: INFO is the cause the guard saw, or `-` if it had no chance to see
  one (SIGKILL, power loss, kernel panic).

(The header row above is for the reader. reduco prints none, so scripts
can consume the output directly.)

### 3.2 Exit status

* `-c` / `-r`: the child's status. If the child was killed by a signal,
  reduco restores the default action and re-raises that signal on itself,
  so the shell sees the same thing it would without reduco (the convention
  of `timeout(1)` and `env(1)`).
* `127` if the command could not be executed, `126` if not executable
  (POSIX shell convention). The record is **kept**, because the program is
  still wanted.
* other modes: `0` on success, `1` on error, with a one-line message on
  stderr.

---

## 4. Record store

### 4.1 Location

1. `-d dir`
2. `$REDUCO_DIR`
3. `$HOME/.reduco` (mirrors abduco's `$HOME/.abduco`)

It **must not** be on a tmpfs (`$XDG_RUNTIME_DIR`, `/tmp`), because records
have to survive a reboot. reduco creates the directory with mode `0700`.
Before reviving anything it refuses a directory that is not owned by the
caller or is group/world writable, as OpenSSH's `StrictModes` does. Reviving
a record executes it, so the store has the same trust level as `~/.profile`.

### 4.2 Layout

Like abduco's socket names, each record carries the hostname so a `$HOME`
shared over NFS does not mix up machines:

```
~/.reduco/
└── work@myhost/
    ├── argv     the command: each argument NUL-terminated (same format as /proc/PID/cmdline)
    ├── cwd      absolute working directory, no trailing newline; hooks may rewrite it (§6.3)
    ├── env/     optional; one file per captured variable, the file's bytes are the value
    ├── keep     optional, empty; present if created with -k
    ├── died     optional; written by the guard when it keeps the record: "SIGTERM", "SIGHUP", "exec: ENOENT", …
    └── lock     empty; the guard holds a POSIX write lock (fcntl F_SETLK) on it while alive
```

Every file is plain and editable. `xargs -0 < argv` re-runs a command,
`printf %s "$PWD" > cwd` moves it, `rm -r` forgets it.

### 4.3 States

| on disk | lock | state | listed as |
|---|---|---|---|
| no directory | — | ended naturally, or never existed | — |
| directory | held | running | `alive` |
| directory | free | ended unnaturally, or `-k` | `dead` → revivable |

`fcntl` record locks are POSIX, work over NFS (through lockd), are not
inherited across `fork`, are dropped by the kernel when the holder dies, and
`F_GETLK` reports the holder's PID. That is everything reduco needs.

### 4.4 Atomic creation (`-c`)

1. `mkdir dir/.name@host.XXXXXX` (a temporary record)
2. write `argv`, `cwd`, `env/`, `keep`; open `lock` with `O_CLOEXEC`, take
   `F_SETLK`
3. `rename()` the temporary directory to `name@host`. rename onto an
   existing non-empty directory fails, so of two racing creators exactly
   one wins.
   * Name taken and its lock held → error `work: alive (pid 4711)`.
   * Name taken and free → error `work: dead, revive with -r or replace with -f`.
     With `-f`, the old record is removed and the rename retried.
4. fork and exec (§5)

### 4.5 Atomic revival (`-r`)

1. open `name@host/lock`, try `F_SETLK`. If that fails, someone else is
   already running or reviving it: error and exit. So `reduco -r work` run
   twice at once starts the program once.
2. read `argv`, `cwd`, `env/`; remove `died`
3. continue as the guard (§5)

---

## 5. The guard

After the record is written and locked, reduco becomes a minimal waiting
parent:

```
export REDUCO=<record dir>  REDUCO_PID=<own pid>
fork
  child:  restore default SIGINT/SIGQUIT (ignored dispositions survive exec)
          chdir(cwd)  (fall back to $HOME with a warning if it is gone)
          apply env/  (on top of the inherited environment)
          execvp(argv)  — on failure write the reason to the parent through a CLOEXEC pipe, _exit(127)
  parent: SIGINT, SIGQUIT  → ignored   (as system(3) does: the tty delivers them to the child too)
          SIGHUP, SIGTERM  → hit = signo (remember, don't forward)
          everything else  → default
          waitpid(child)
          if hit == 0 and no keep file:  remove the record          ← natural end
          else:                          write died = cause, keep    ← the world ended
          propagate the child's status (§3.2)
```

### 5.1 Why "the guard was signalled" is the right test

* **Reboot / shutdown.** init or systemd sends SIGTERM to every process
  at once (`kill(-1)` or a cgroup kill). The guard's handler runs before
  `waitpid` returns, so `hit` is already set when the child's exit is
  processed → kept.
* **Logout with KillUserProcesses, or killing the session scope:** same as
  shutdown → kept.
* **Host dies** (abduco server killed, terminal emulator closed). The pty
  hangs up and the kernel sends SIGHUP to the session leader and the
  foreground group. Under abduco the guard *is* the session leader, since
  abduco's `forkpty` child execs it → kept.
* **SIGKILL, power loss, panic.** The guard never runs cleanup, the record
  stays, the lock is gone → dead (`died` absent, listed as `-`).
* **User quits the program** (`exit`, `:q`, dvtm quit, Ctrl-C to a
  foreground job). The child ends, the guard was not touched → removed.

The child's own exit status is deliberately **not** used: shells exit
non-zero all the time, and a program killed by a signal is often the user
pressing Ctrl-C. "Did the world end around us?" is the signal that carries
the meaning, and only the guard can observe it.

### 5.2 What the guard does *not* do

* no signal forwarding. The child shares the guard's process group, and
  shutdown, hangup and tty signals reach it directly. (Open question:
  forward a SIGTERM aimed at the guard's PID alone? §11)
* no restarting. That is supervision (runit, s6, systemd `Restart=`).
  reduco only revives on request, after the fact.
* no terminal handling, no setsid, no pty. reduco is transparent to
  whatever terminal it is in.
* no timers, no polling, no background threads. While the program runs,
  reduco sleeps in `waitpid`.

Cost per guarded program: one sleeping process of a few hundred KiB.

---

## 6. Capturing "the same place"

### 6.1 argv

Exact bytes, NUL-separated. No shell parsing and no quoting problems.
`reduco -c x sh -c 'complex | pipeline'` works as you would expect.

### 6.2 cwd at start

`getcwd()` at create time. This is all a non-shell program needs.

### 6.3 cwd that moves (shells)

A shell started in `~` that has since `cd`'d to `~/src/x` should come back
in `~/src/x`. A tool built for "after the world ended" can't rely on asking
the dying process, and reading another process's cwd is not portable
(`/proc` on Linux, different sysctls on the BSDs, `libproc` on macOS). So
reduco exports two variables and lets the program report back:

```sh
# ~/.profile / ~/.bashrc / ~/.zshrc: keep the record's cwd current
reduco_cwd() {
	[ "$PPID" = "$REDUCO_PID" ] && printf '%s' "$PWD" > "$REDUCO/cwd"
}
# bash: PROMPT_COMMAND="reduco_cwd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
# zsh:  chpwd_functions+=(reduco_cwd)
# fish: function reduco_cwd --on-variable PWD; …; end
```

The `$PPID = $REDUCO_PID` check means only the *direct* child of a guard
writes. Shells in dvtm panes under a guarded dvtm don't overwrite dvtm's
record; each pane can have its own guard (§7.3). The hook writes a plain
file, so it forks nothing.

A platform-specific "probe the child's cwd on SIGTERM" could be added later
behind a compile-time option (§10, phase 6). It is not in the portable core.

### 6.4 Environment: inherit by default

After a reboot, most of a captured environment is **stale**:
`SSH_AUTH_SOCK`, `DISPLAY`, `WAYLAND_DISPLAY`, `DBUS_SESSION_BUS_ADDRESS`,
`XDG_RUNTIME_DIR`, `ABDUCO_SOCKET`, `TMUX`, `STY`, `SHLVL`, `OLDPWD`.
Restoring them breaks things quietly. So by default a revived program gets
**the reviver's current environment**, which is fresh, the same way a newly
started program would. Variables that were part of the intent
(`EDITOR=vis reduco -c …`) are captured explicitly with `-e EDITOR`, or all
of them with `-E` if you really want that.

---

## 7. Composition: how reduco meets other tools

In every case below the host is chosen at **revival** time, by the caller.
reduco itself never names a host.

### 7.1 abduco + dvtm (the termstead stack)

```sh
# start
abduco -c work reduco -c work dvtm

# after a reboot, bring every dead session back as a detached abduco session
reduco | awk -F'\t' '$1 == "dead" { print $2 }' |
while read -r name; do
	abduco -n "$name" reduco -r "$name"
done
```

Process tree: `abduco server → reduco (guard, session leader) → dvtm`.
Quitting dvtm removes the record and ends the abduco session. Rebooting
leaves a dead record that the loop revives.

The two names being equal is a convention, not a requirement. A
three-line wrapper (`rabduco`, shipped in `contrib/`) can make it one word
without either tool knowing about the other.

### 7.2 any other host

```sh
dtach -n /tmp/work.sock reduco -r work          # dtach
tmux new -d -s work 'reduco -r work'            # tmux (yes, even tmux)
screen -dmS work reduco -r work                 # screen
systemd-run --user --unit=work reduco -r work   # a transient service
setsid -f reduco -r work                        # bare background
reduco -r work                                  # right here, in this terminal
```

### 7.3 per-window revival inside dvtm

dvtm runs each positional argument in its own window, and its command FIFO
accepts `create "cmd" "title" "cwd"`. Pane-level revival is therefore a
small script with no changes to dvtm:

```sh
#!/bin/sh
# contrib/reduco-dvtm: start dvtm with every dead pane record revived as a window
export REDUCO_DIR="${REDUCO_DIR:-$HOME/.reduco}/${1:?session}.panes"
set --
for n in $(reduco | awk -F'\t' '$1 == "dead" { print $2 }'); do
	set -- "$@" "reduco -r $n"
done
exec dvtm "$@"
```

For new panes to be guarded, dvtm's shell only has to be
`reduco -c <auto-name> $SHELL`. That needs automatic names (§11, Q4). The
window *layout* (master area, tags, focus) is dvtm's state and stays dvtm's
concern (L2).

### 7.4 automatic revival at boot or login

reduco does not schedule anything. Use what you already have:

* `~/.profile`: the loop from §7.1, guarded by "only in the first login
  shell"
* cron: `@reboot` with the loop
* a systemd user unit with `ExecStart=` the loop, `Type=oneshot`

`contrib/` ships `reduco-reviveall` (the loop, with the host command as an
argument, defaulting to `abduco -n %s`) as an example, not as a feature.

---

## 8. How it compares

| | layer | host-coupled | needs daemon / polling | restarts | survives reboot | portable |
|---|---|---|---|---|---|---|
| tmux-resurrect + continuum | L1 + L2 | tmux only | timer | no | yes (snapshot) | wherever tmux runs |
| zellij resurrection | L1 + L2 | zellij only | periodic serialization | no | yes | wherever zellij runs |
| systemd `Restart=` | supervision | systemd | systemd | immediately | if enabled | Linux |
| runit / s6 / daemontools | supervision | none | supervisor | immediately | if service | POSIX |
| CRIU / DMTCP | L0 | none | no | no | sometimes | Linux, root/caps |
| **reduco** | **L1** | **none** | **no** | **no, only on request** | **yes** | **POSIX** |

What sets it apart: it's for **ad-hoc, interactive programs a user started
by hand**, it brings them back **after** a catastrophe and not during one,
and it needs no host and no daemon.

---

## 9. Limits (stated, not hidden)

* **Daemonizing programs.** If `command` forks into the background and
  exits, the guard sees a natural end and deletes the record. Wrap
  foreground programs (the same rule supervisors have). Most daemons have
  a `-f`/`-D`/`--foreground` flag.
* **Guard killed alone.** `kill -9 <guard>` leaves the child running and the
  record looking dead, so a revival would start a duplicate. Mitigation in
  phase 6: store the child PID and warn on `-r` if it still exists (a
  warning only, because of PID reuse).
* **Inner state is not revived.** If the shell was running `vim` inside it,
  you get the shell back, not vim. Guard vim itself
  (`reduco -c notes vim notes.md`) if it should come back. That is the
  composable answer to tmux-resurrect's allowlist of programs to restore.
* **Scrollback and screen contents.** Not reduco's. They belong to the host
  or a separate tool (for example a `script(1)`-style logger).
* **A natural end during shutdown.** If a program finishes by itself
  during the SIGTERM wave, it is kept, because the guard can't tell. The
  error leans toward keeping, which is the safe direction.

---

## 10. Plan

Each phase is small, testable on its own, and leaves a working tool.

### Phase 0: skeleton
* `reduco.c`, `config.def.h` (default dir name, name charset), `Makefile`
  (abduco-style, with `CFLAGS_STD = -std=c99 -D_POSIX_C_SOURCE=200809L`),
  `reduco.1` (mdoc), `README.md`, `testsuite.sh`
* `-v`, usage, `die()`/`warn()` helpers
* CI: gcc and clang on Linux, plus macOS and FreeBSD (POSIX portability is a
  feature, so it should be tested)

**Done when** `make && ./reduco -v` works on all three.

### Phase 1: record store
* directory resolution (`-d`, `$REDUCO_DIR`, `$HOME/.reduco`), creation
  `0700`, ownership/permission check
* name validation, `name@host` naming
* write/read `argv`, `cwd`; liveness through `F_GETLK`
* list (§3.1), `-p`, `-x`

**Tests:** hand-made record directories are listed correctly. `-p` output
run by `sh` gives the same argv, including arguments with spaces, quotes,
newlines and empty strings. `-x` refuses a locked record.

### Phase 2: create and guard
* atomic create (§4.4), the `-f` and `-k` semantics
* fork/exec with the exec-error pipe, signal disposition, `waitpid`
* death classification (§5), `died` file, status propagation (§3.2)
* `REDUCO`, `REDUCO_PID` exports

**Tests (the core of the suite):**
| scenario | how | expect |
|---|---|---|
| natural end | `reduco -c t true` | no record, status 0 |
| non-zero exit | `reduco -c t false` | no record, status 1 |
| child killed (Ctrl-C) | `reduco -c t sleep 9 &`, `kill -INT <child>` | no record, guard re-raises SIGINT |
| shutdown | `kill -TERM <guard> <child>` | record `dead`, `died` = `SIGTERM` |
| hangup | run under a pty, close master | record `dead`, `died` = `SIGHUP` |
| crash / power loss | `kill -KILL <guard> <child>` | record `dead`, `died` absent |
| exec fails | `reduco -c t /nonexistent` | status 127, record kept |
| name collision | two `-c t` at once | exactly one runs |
| keep | `reduco -k -c t true` | record `dead` after exit |

### Phase 3: revive
* lock-first revive (§4.5), cwd fallback, env overlay
* concurrency: two `-r t` at once start it once
* a revived record is guarded again, so it can die and be revived again
  indefinitely

**Tests:** create, crash (`-KILL`), revive, crash, revive: same argv and cwd
each time. Revive with a deleted cwd lands in `$HOME` with a warning.

### Phase 4: environment and cwd tracking
* `-e var`, `-E`, `env/` read/write
* document and test the shell hooks (sh, bash, zsh, fish) in `reduco.1`
  and `contrib/`
* only the direct child writes cwd (`$PPID` check), tested with a nested
  shell

### Phase 5: composition kit (`contrib/`, outside the binary)
* `rabduco`: `abduco -c NAME reduco -c NAME …`
* `reduco-reviveall [host-template]`: the revival loop
* `reduco-dvtm`: per-pane revival (§7.3), plus automatic names if Q4 is
  accepted
* example systemd user unit and cron line
* end-to-end test: `abduco -n` + `reduco`, kill the abduco server, revive,
  `abduco -a` shows the program back in the right directory

### Phase 6: hardening, optional
* warn on `-r` when the recorded child PID still exists (§9)
* compile-time `PROBE_CWD`: on SIGTERM, read the child's cwd through the
  platform interface (`/proc`, `KERN_PROC_CWD`, `proc_pidinfo`) before it
  disappears
* fuzz the record parser with malformed directories

### Release 0.1 = phases 0–4 plus the `contrib/` scripts.

---

## 11. Open questions

1. **Store location.** `$HOME/.reduco` (abduco symmetry, chosen above) or
   `$XDG_STATE_HOME/reduco` (the "right" XDG place for data that must
   survive a reboot)?
2. **Child killed while the guard was untouched** (OOM killer, `kill -9`
   on the child). Currently: natural end, record removed. Should it be
   kept instead? Keeping is safer but also keeps things the user
   `kill -9`'d on purpose.
3. **Signal forwarding.** Forward a SIGTERM/SIGHUP that targets only the
   guard's PID to the child? It makes `kill <guard>` "just work", but
   group-wide signals would then be delivered twice.
4. **Automatic names.** `reduco -c - cmd` → first free `1`, `2`, …? Needed
   for guarding dvtm panes from dvtm's create binding. Otherwise names
   stay mandatory, like abduco session names.
5. **Language.** C99 like abduco and dvtm (assumed throughout), to share
   build, style and portability with the rest of termstead.
