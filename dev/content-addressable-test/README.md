# Content-addressable gems — manual end-to-end test

Manual, native-macOS (darwin) tests for **content-addressable ("skinny")
precompiled gems**. 

A *skinny* binary is a platformed gem pinned to a single Ruby ABI (here the
demo's `required_ruby_version = "~> 3.3.0"`). These are built, named, installed,
and resolved by **content address** — `name-version-<sha>`, where
`<sha> = sha256(.gem)[0, 10]` — so multiple per-Ruby builds of the same
version+platform can coexist and the right one is fetched at resolve time.

## What's here

| File | Purpose |
| --- | --- |
| `demo/` | A tiny native gem (`hola`) with a one-ABI `required_ruby_version`, so it builds as a skinny/content-addressable binary. |
| `fake_compact_index.rb` | ~40-line, dependency-free threaded HTTP server that serves a directory as a compact index (`/v2/versions`, `/v2/info/<gem>`, `/gems/*.gem`). |
| `test_local.sh` | Builds + installs the gem and exercises `bundle install --local`. |
| `test_remote.sh` | Renders compact-index files, starts the fake server, and exercises a real remote `bundle install`. |
| `test_remote_mixed.sh` | One Gemfile spanning a v2 source (content-addressable gem) and a scoped v1-only source (traditional gem), proving per-source API negotiation in a single `bundle install`. |

## Requirements

- A clean Ruby matching the demo's `~> 3.3.0` (default `/opt/rubies/3.3.5`).
  Override with `RUBY_PREFIX=/opt/rubies/3.3.x`.
- A C toolchain (Xcode CLT `clang`).
- Network access on first run (to `gem install rake-compiler` from rubygems.org).

The scripts auto-locate this rubygems checkout (two levels up) and load the
**patched** RubyGems + Bundler from it.

## How to run

```bash
cd dev/content-addressable-test
./test_local.sh              # bundle install --local path
./test_remote.sh             # remote path via the fake compact-index server
./test_remote_mixed.sh       # v2 source + scoped v1 source in one Gemfile
```

> **Note:** these scripts honor a `PORT` env var. If you have `PORT` exported
> in your shell (e.g. pointing at a dev-services proxy on `8080`), pass an
> explicit one: `PORT=8898 ./test_remote_v1.sh`.

Each prints every step and ends with `ALL GOOD`.

## What each test proves

### `test_local.sh`
1. `rake native gem` builds the skinny gem and renames it
   `hola-1.0.0-<platform>.gem` → `hola-1.0.0-<sha>.gem` (in `Gem::Package.build`).
2. `gem install --local` installs it under `gems/hola-1.0.0-<sha>/` and records
   the sha in the stub line (`# stub: hola 1.0.0 <platform> lib <sha>`), so
   `full_name` reconstructs the content-addressed name offline.
3. `bundle install --local` resolves the content-addressed gem, including the
   **lockfile round-trip**: the lock stays portable (`hola (1.0.0-<platform>)`),
   and Bundler bridges that back to the on-disk `name-version-<sha>` gem.
4. `bundle exec require "hola"` and `bundle list` work; re-running install is
   idempotent.

### `test_remote.sh`
1. Builds the same gem and renders a compact index from it. The
   content-addressable info line is:
   ```
   1.0.0-<sha> |checksum:<sha256-hex>,ruby:<req>,platform:<real-platform>
   ```
   - the version slot's "platform" = the **content address** (`<sha>`) → becomes
     the gem's `full_name` and the download path `/gems/hola-1.0.0-<sha>.gem`;
   - the `platform:` **metadata token** carries the real platform, used for
     compatibility matching.
2. Bundler probes `/v2/versions`, fetches `/v2/info/hola`, resolves
   `hola 1.0.0 (<sha>)`, downloads `/gems/hola-1.0.0-<sha>.gem`, installs it, and
   `require` works.

### `test_remote_mixed.sh`
Runs **two** fake servers behind one Gemfile -- a v2 source and a scoped
v1-only source:
```ruby
source "http://127.0.0.1:<v2>"        # content-addressable (skinny) hola
gem "hola"

source "http://127.0.0.1:<v1>" do     # legacy v1-only source (saludo)
  gem "saludo"
end
```
1. For the v2 source the client fetches `/v2/info/hola`, resolves
   `hola 1.0.0 (<sha>)`, and downloads `/gems/hola-1.0.0-<sha>.gem`.
2. For the v1 source the client probes `GET /v2/versions`, gets a **404**, and
   transparently downgrades to v1 (see
   `CompactIndexClient#negotiate_api_version!`) -- fetching the unprefixed
   `/versions` + `/info/saludo` and downloading `/gems/saludo-1.0.0.gem`. No
   `<sha>` token, no `/v2/info` request.
3. Asserts both gems install and `require`, the lockfile records each under its
   own remote, and there is no cross-source leakage. This exercises the
   **per-source** API negotiation: the cache + version marker are keyed by
   `remote.cache_slug`, so v2 and v1 sources coexist in a single resolve.

## Gotchas (learned the hard way; encoded in the scripts)

- **Use the released `rake-compiler`, not a dev branch.** Content-addressing
  lives entirely in core `Gem::Package.build`; no rake-compiler patch is needed.
- **Bundle must load the patched rubygems core**
  (`RUBYOPT="--disable-gems -I<repo>/lib -rrubygems"`), not Ruby's built-in
  rubygems. Otherwise the `<sha>` platform token parses to the bogus platform
  `"unknown"` and the download 404s on `hola-1.0.0-unknown.gem`. (The patched
  `lib/rubygems/platform.rb` preserves a 10-hex-char content address verbatim.)
- **Put the build Ruby first on `PATH`** so `bundle exec ruby` matches the build
  platform. On darwin the OS version is baked into the platform string
  (`arm64-darwin-23` vs `arm64-darwin-24`); a mismatch yields `GemNotFound`.
- **Point `GEM_HOME` and Bundler's `bundle_path` at the same dir** so
  `gem install` and `bundle install --local` agree on where the gem lives.

## Known nuance

On the **remote** path the gem currently installs into
`gems/hola-1.0.0-<real-platform>/`, whereas the **`--local`** path installs into
`gems/hola-1.0.0-<sha>/`. Both are internally consistent and work for a single
active Ruby, but they disagree on the on-disk directory name. True
side-by-side coexistence of two Ruby ABI builds on the remote path would
require Bundler's installer to preserve the content address into the install
dir like `gem install` does.
