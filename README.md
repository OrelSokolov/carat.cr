# carat

**A package manager for Crystal, built around the RubyGems workflow.**

In Ruby, a package can be a tool: `gem install` gives you a working binary in
one command, immediately useful. Crystal shards never had that — a CLI shard
meant `git clone`, `crystal build`, and hand-editing your PATH.

carat fixes it:

```
$ carat install OrelSokolov/hello_binary
$ hello_binary
hello_binary 1.1.0: Hello from a carat-installed shard!
```

One command: the shard is fetched from GitHub, its `executables:` are built
with `crystal build --release`, and self-contained binaries land in
`~/.carat/bin` — on your PATH, ready to use. No manual installs, no PATH
pain, no "first clone five repos and read the README".

## The idea

A package should bring value the moment it's downloaded. If a shard ships a
binary — a CLI tool, a code generator, a formatter — installing it should be
as simple as installing a gem:

| Ruby                  | Crystal with carat                  |
| --------------------- | ----------------------------------- |
| `gem install rubocop` | `carat install crystal-tools/linter` |
| `rubocop` just works  | `linter` just works                  |

carat treats `executables:` in `shard.yml` as a first-class delivery format,
not a build hint: the binary **is** the package. Libraries keep working the
usual way — `carat install` inside a project delegates to `shards install`.

## Quick start

```bash
carat install owner/repo        # from GitHub: owner/repo shorthand
carat install name              # bare name → github.com/<name>/<name>
carat install https://github.com/owner/repo.git
carat install ~/code/my-tool    # local checkout
```

Sources are resolved in that order; the built binaries are the same in every
case.

## Commands

| Command                  | Behavior                                                            |
| ------------------------ | ------------------------------------------------------------------- |
| `carat install <src>`    | Global install: clone → release build → binaries in `~/.carat/bin`  |
| `carat install`          | In a project: delegates to `shards install`, builds `executables:` into `./.carat/bin` |
| `carat update <src>`     | Compares the installed version with the remote; installs if newer  |
| `carat exec <cmd> [args]`| Like `bundle exec`: runs `<cmd>` with `./.carat/bin` prepended to PATH |

## Make your shard instantly installable

If your shard already has an `executables:` entry and an entrypoint in
`src/`, it is already carat-ready — publish and share the `owner/repo` slug:

```yaml
# shard.yml
name: hello_binary
version: 1.1.0
executables:
  - hello_binary
```

```
src/hello_binary.cr   # entrypoint; built with crystal build --release
```

Bump the version in `shard.yml`, push — every user's `carat update` picks it
up. No releases page, no tarballs, no install scripts.

## What happens on install

1. **Fetch** — `git clone --depth 1` into a staging dir (local directories
   are copied as-is).
2. **Store** — sources are archived at `~/.carat/shards/<name>/<version>/`
   with a `current` version pointer, so installed versions are inspectable
   and switchable later.
3. **Build** — every `executables:` entry is compiled with
   `crystal build --release` from the stored copy and validated by magic
   bytes (ELF / Mach-O / PE) before it's allowed into the bin dir.
4. **Link** — the binary is renamed into `~/.carat/bin/`. Overwriting an
   existing binary always prints `WARNING: OVERWRITING WITH NEW BINARY` and
   is recorded in the audit log (`~/.carat/logs/carat.log`), so silent
   hijacking of your PATH is impossible.

## Layout

```
~/.carat/bin/                    global binaries (entry points only)
~/.carat/shards/<name>/<ver>/    source store, per version
~/.carat/shards/<name>/current   installed version pointer
~/.carat/logs/carat.log          install/overwrite/update audit log
~/.carat/tmp/                    staging for clones
./.carat/bin/                    project binaries (carat install / carat exec)
```

Only self-contained binaries ever go into the bin dir — no assets, no
wrappers, no PATH pollution.

## Installing carat

No packages, no sudo — carat is a plain console binary:

```bash
git clone https://github.com/OrelSokolov/carat.cr.git && cd carat.cr
rake install
```

`rake install` builds the release binary, copies it to `~/.carat/bin` (the
first binary there is carat itself) and appends `~/.carat/bin` to your PATH
— `~/.bashrc` / `~/.zshrc` on Unix, the user PATH on Windows. Idempotent:
run it as many times as you like.

On a fresh host without a toolchain, [crosspack](https://github.com/OrelSokolov/crosspack)
sets it up first: `gem install crosspack && crosspack deps`.

After that, carat updates itself like any other shard:

```bash
carat update OrelSokolov/carat.cr
```

Rebuilding over the running binary is safe (build-to-temp + rename).

## Status and roadmap

v0.1 focuses on the core promise: gems-style install of binary shards from
GitHub and local checkouts.

Next:

- Shardbox lookup for bare names, `carat use <name>@<ver>` version switching
- `carat list` / `carat uninstall`
- Full dependency resolution on a fork of shards — carat as the single
  package manager replacing it

## License

MIT — see [LICENSE](LICENSE).
