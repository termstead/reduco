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

Early development: only `-v` is implemented so far.
