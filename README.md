<p align="center">
  <img src="logo.png" width="180" alt="carat logo — a faceted diamond" />
</p>

# carat

**All-in-one package manager for Crystal.**

Extends `shard.yml` with a `binaries:` section — **fully compatible with
standard Crystal installs**: `shards install` / `shards build` / shard.lock
keep working untouched (shards simply ignores the extra key).

- **Build and share your Crystal shards like Ruby gems** — a package can be
  a tool you *use right now*, not just a library you require.
- **System-wide install as a system binary** — `carat install owner/repo`
  puts a ready-to-run release binary into `~/.carat/bin` (on your PATH).
  One command, immediately useful. No manual installs, no PATH pain.
- **Compile flags per target system** — Windows, Linux and Darwin often
  need different (link) flags; `binaries:` in shard.yml declares them
  per OS, so the same shard builds everywhere.
- **Real-world builds** — custom `main:` files, native `prebuild:` steps
  (rake/cmake/make), explicit archives and link flags: GUI and app shards
  install as easily as hello-world CLIs.
- **Project mode too** — `carat install` in a project delegates to
  `shards install` and builds binaries into `./.carat/bin`;
  `carat exec` runs them like `bundle exec`.
- **Self-hosting** — carat installs and updates itself through carat.
- **Shell autocompletion out of the box** — bash, fish and zsh: `carat exec
  <TAB>` completes your project binaries (see
  [Shell autocompletion](#shell-autocompletion)).

In Ruby, a package can be a tool: `gem install` gives you a working binary
in one command, immediately useful. Crystal shards never had that — a CLI
shard meant `git clone`, `crystal build`, and hand-editing your PATH.
carat fixes it:

```
$ carat install OrelSokolov/hello_binary
$ hello_binary
hello_binary 1.1.0: Hello from a carat-installed shard!
```

One command: the shard is fetched from GitHub, its `binaries:` are built
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

carat treats `binaries:` in `shard.yml` as a first-class delivery format:
the binary **is** the package. Libraries keep working the usual way —
`carat install` inside a project delegates to `shards install`.

## Quick start

```bash
carat install owner/repo        # from GitHub: owner/repo shorthand
carat install name              # bare name → github.com/<name>/<name>
carat install https://github.com/owner/repo.git
carat install ~/code/my-tool    # local checkout
carat install .                 # the shard in the current directory — global
                                 # install while developing it locally
```

Sources are resolved in that order; the built binaries are the same in every
case.

## Commands

| Command                  | Behavior                                                            |
| ------------------------ | ------------------------------------------------------------------- |
| `carat install <src>`    | Global install: clone → release build → binaries in `~/.carat/bin`  |
| `carat install .`        | Global install of the shard in the current dir (local development)  |
| `carat install`          | In a project: delegates to `shards install`, builds `binaries:` into `./.carat/bin` |
| `carat update <src>`     | Compares the installed version with the remote; installs if newer  |
| `carat update`          | In a project: delegates to `shards update`, rebuilds `./.carat/bin` |
| `carat dev install`     | Like `install`, but builds with a plain `crystal build` (no `--release`): faster codegen for development iteration |
| `carat dev update`      | Same for `update`                                                   |
| `carat only install`    | Like `install`, but only runs `shards install` — no binary build (drop-in `shards install` compatibility) |
| `carat only update`     | Same for `update` (`shards update` only)                            |
| `carat exec <cmd> [args]`| Like `bundle exec`: runs `<cmd>` with `./.carat/bin` prepended to PATH |
| `carat self install`     | Install-or-update carat itself from the canonical repo (`OrelSokolov/carat.cr`); `carat self update` is the same thing |
| `carat completion install` | Install shell autocompletion (bash / fish / zsh)                       |

Both `install` and `update` accept:

- `--with-examples` — also build the optional `examples:` section (see below)
- `--system` — install binaries into the system directory instead of
  `~/.carat/bin`: `/usr/local/bin` on Linux/macOS (on PATH by default),
  `%ProgramFiles%\carat\bin` + the machine PATH on Windows. Requires
  root/Administrator; without the rights carat fails fast — before any
  clone or build — with a clear error. The version store stays in
  `~/.carat/shards`, so `carat update` keeps working.

## Make your shard instantly installable

Add a `binaries:` section to shard.yml — carat's delivery contract. The
simplest form is a list (entrypoints default to `src/<name>.cr`):

```yaml
binaries:
  - hello_binary
```

The full form covers real-world builds — custom main files, native
prebuild steps, compiler and linker flags that differ per OS:

```yaml
binaries:
  widgets_gallery:
    main: examples/widgets_gallery.cr    # any file, not just src/
    prebuild: rake build:native          # native build step, run in the shard root first
    flags:                               # crystal build flags
      "*": [--something]
      darwin: [-DUSE_METAL=0]
    link_flags:                          # linker flags, per-OS selectors
      "*": [-Llib]
      linux: [lib/libfoo.a]              # explicit archive — ld order safe
      windows: [/LIBPATH:lib]
```

### Shared keys: `all:` and `each:`

In the mapping form two reserved keys control the whole section — no need
to repeat the same spec on every binary:

```yaml
binaries:
  all:                      # ONCE per section, before any binary is built
    prebuild: rake build:native
  each:                     # defaults for EVERY binary (own keys override)
    flags: [-DSOME=1]
  hello: {}                 # gets each:'s flags, all:'s prebuild already ran
  widgets_gallery:
    main: examples/widgets_gallery.cr
  tool:
    flags: [-DOTHER=1]      # own flags win over each:'s
```

- `all:` — the section-wide step: its `prebuild` runs **one time** before
  the section's builds (the shared native step — not once per binary), its
  `flags`/`link_flags` are the base for every binary.
- `each:` — per-binary defaults: `prebuild` runs before **each** binary,
  `flags`/`link_flags` apply to each unless the binary overrides them.
- Precedence: the binary's own keys > `each:` > `all:`. Neither key is a
  binary itself.

Dependencies declared in `dependencies:` are resolved automatically: a
global install runs `shards install` in the stored copy before building,
so shards with dependencies install as smoothly as dep-free ones.
`prebuild:` stays for native build steps (rake/cmake/make), not for
dependency resolution.

Selector resolution follows crosspack's `hosts:` rules: exact OS family
(`linux` / `darwin` / `windows`), then `*` — first hit wins. A plain list
instead of a mapping applies to every OS. Relative paths in `link_flags`
are resolved against the shard root (mold/ld do not open relative
`--link-flags` paths).

Bump the version in shard.yml, push — every user's `carat update` picks it
up. No releases page, no tarballs, no install scripts.

`shards` ignores the extra `binaries:` key, so the shard stays a perfectly
normal shard — `shards install` / `shards build` keep working (verified
with shards 0.20).

### Optional examples: `examples:`

`examples:` is the same contract as `binaries:` (list or full mapping
form), but for demo/sample binaries. It is **never built by default** —
recursive installs would balloon quickly — only on demand:

```bash
carat install owner/repo --with-examples   # global: binaries in ~/.carat/bin,
                                           # examples in ~/.carat/examples
carat install --with-examples              # project: examples in ./.carat/examples
```

```yaml
examples:
  widgets_gallery:
    main: examples/widgets_gallery.cr
```

Example binaries land in a separate dir (`~/.carat/examples` /
`./.carat/examples`), so they never pollute your PATH.

### Build flags from dependencies

A shard's binaries often link C libraries through binding shards. A
**dependency** may declare top-level `flags:` / `link_flags:` in its own
shard.yml (same per-OS selector format), and carat applies them when
building binaries of any shard that depends on it:

```yaml
# lib/some_binding/shard.yml
name: some_binding
version: 1.0.0
flags:
  "*": [-DSOME_BINDING=1]
link_flags:
  linux: [-lsome]
```

Flags are collected recursively from `lib/**/shard.yml` (populated by
`shards install`; in global installs — by a `prebuild:` step), merged
with the binary's own flags and deduplicated (own flags first, order
preserved). The merged list is printed during the build, so what the
compiler actually received is always visible. `shards` ignores these
keys, so the dependency stays a normal shard.

## What happens on install

1. **Fetch** — `git clone --depth 1` into a staging dir (local directories
   are copied as-is).
2. **Store** — sources are archived at `~/.carat/shards/<name>/<version>/`
   with a `current` version pointer, so installed versions are inspectable
   and switchable later.
3. **Resolve** — shards with `dependencies:` get a `shards install` run
   in the stored copy (the compiler resolves bare requires from lib/).
4. **Build** — every `binaries:` entry is compiled with
   `crystal build --release` from the stored copy and validated by magic
   bytes (ELF / Mach-O / PE) before it's allowed into the bin dir.
   Entries build in a worker pool: concurrent `crystal build` processes
   scale ~N in wall-clock, and the pool width is derived from the
   machine's current state (CPU cores, `MemAvailable` / the peak
   compiler RSS measured while the first build warms its cache slot):
   `workers = min(cores, MemAvailable * 0.7 / peak_rss, 8)`. Before
   handing out each next job a gate re-checks free RAM and stalls the
   queue when it runs low, and a build that still died (an OOM is
   exit 137 / SIGKILL) is retried once sequentially. Each worker keeps
   its own persistent compiler cache (`<shard>/.carat/cache/jN`) —
   concurrent compilers race on the shared `~/.cache/crystal`. Set
   `CARAT_JOBS=N` to bypass the adaptive sizing (benchmarks, A/B runs).
5. **Link** — the binary is renamed into `~/.carat/bin/`. Overwriting an
   existing binary always prints `WARNING: OVERWRITING WITH NEW BINARY` and
   is recorded in the audit log (`~/.carat/logs/carat.log`), so silent
   hijacking of your PATH is impossible. (Global installs only — project
   rebuilds into `./.carat/bin` stay quiet: overwriting your own build is
   the normal dev loop.)

## Layout

```
~/.carat/bin/                    global binaries (entry points only)
~/.carat/examples/               global example binaries (--with-examples)
~/.carat/shards/<name>/<ver>/    source store, per version
~/.carat/shards/<name>/current   installed version pointer
~/.carat/logs/carat.log          install/overwrite/update audit log
~/.carat/tmp/                    staging for clones
./.carat/bin/                    project binaries (carat install / carat exec)
./.carat/examples/               project example binaries (--with-examples)
./.carat/cache/jN/               per-worker crystal compiler caches (build pool)
```

Only self-contained binaries ever go into the bin dir — no assets, no
wrappers, no PATH pollution.

## Shell autocompletion

```
carat completion install
```

- **bash** — registers `complete -C carat carat` in the XDG bash-completion
  dir (`~/.local/share/bash-completion/completions/`): no rc edits, live on
  the first TAB in a new shell.
- **fish** — writes `~/.config/fish/completions/carat.fish` (when fish is
  installed).
- **zsh** — prints a two-line `bashcompinit` snippet for `~/.zshrc`.

What completes:

- `carat <TAB>` — subcommands (`install`, `update`, `exec`, `completion`,
  `--help`, `--version`)
- `carat exec <TAB>` — the binaries of the current project (`./.carat/bin`):
  `carat` itself is excluded, and only the first argument is completed —
  the words after it belong to the launched program, and a fully typed
  word is never re-offered (no duplicate inserts on repeated TABs)
- `carat update <TAB>` — globally installed shards

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
carat self update        # = carat update OrelSokolov/carat.cr;
                          # carat self install does the same (install-or-update)
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
