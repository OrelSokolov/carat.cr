# carat

Global binary installer for Crystal shards — `gem install` UX for shard
executables.

    carat install OrelSokolov/hello_binary   # clone → release build → ~/.carat/bin
    carat install                            # in a project: shards install + ./.carat/bin
    carat update OrelSokolov/hello_binary    # update if remote version is newer
    carat exec <cmd> [args]                  # run with ./.carat/bin prepended to PATH

## First install (bootstrap via crosspack)

carat bootstraps itself through [crosspack](https://github.com/OrelSokolov/crosspack):

    gem install crosspack
    crosspack deps        # verify/install build deps (crystal, git, shards)
    crosspack build       # compile carat into builds/
    crosspack pack        # distro package (deb / rpm / PKGBUILD / MSI)
    crosspack install     # install this host's package

## Updating carat

After the first install, carat updates itself like any other shard:

    carat update OrelSokolov/carat

The self-update lands in `~/.carat/bin/carat` — keep `~/.carat/bin` ahead of
`/usr/local/bin` in PATH so the fresh binary wins over the packaged one.
Rebuilding over the running binary is safe (build-to-temp + rename).

## Layout

    ~/.carat/bin/                    global binaries (entry points only)
    ~/.carat/shards/<name>/<ver>/    source store, per version
    ~/.carat/shards/<name>/current   installed version pointer
    ~/.carat/logs/carat.log          install/overwrite/update audit log
    ./.carat/bin/                    project binaries

Overwriting a binary always prints `WARNING: OVERWRITING WITH NEW BINARY`
and is recorded in the audit log.
