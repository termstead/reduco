# reduco

abduco takes a program away from its terminal; **reduco** brings it back
after its world ended (reboot, logout, crash, host killed).

## Build

```sh
make
./reduco -v
make test
make install
```

Configuration is done by copying `config.def.h` to `config.h` (done by
`make` on first build) and editing it.

## Status

Early development. Implemented so far: the record store (list, `-p`, `-x`).
Creating, guarding and reviving records are not implemented yet.

```
reduco [-d dir]            list records
reduco [-d dir] -p name    print a record as a sh(1) command line
reduco [-d dir] -x name    delete a dead record
reduco -v                  version
```

Records live in `-d dir`, `$REDUCO_DIR` or `$HOME/.reduco`, in directories
named `name@host`.
