# reduco: bring programs back

abduco takes a program away from its terminal; **reduco** brings it back
after its world ended (reboot, logout, crash, host killed).

It remembers how a program was started (command and working directory),
notices whether it ended on purpose or was killed, and starts it again on
request. It doesn't know or care what it runs under: abduco, dvtm, dtach,
tmux, a systemd unit or a plain shell.

```sh
abduco -c work reduco -c work dvtm        # start, guarded

# ... reboot ...

reduco                                    # what died?
dead	work	SIGTERM	/home/u/src	dvtm

abduco -n work reduco -r work             # bring it back, in any host you like
```

Status: **design phase**, nothing is implemented yet. See [DESIGN.md](DESIGN.md)
for the model, the interface and the implementation plan.
