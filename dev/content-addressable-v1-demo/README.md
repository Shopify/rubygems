# Content-addressable gems in the **v1** compact index — resolution proof

This prototype implements the proposal where
content-addressable ("skinny") gems are **directly in the v1 compact index**
, gated by a `rubygems:>=` requirement so that:

- **old clients ignore** the skinny rows (they don't satisfy `rubygems:>=`), and
- **new clients process** them, match on the `platform:` metadata token, and
  download the content-addressed `name-version-<sha>.gem`.

A skinny `/info/hola` entry looks like (content-addressable rows last):

```
---
1.0.0                      |checksum:…,ruby:>= 3.1,rubygems:>= 3.3.22
1.0.0-x86_64-linux         |checksum:…,ruby:>= 3.1
1.0.0-ef716ba7a6           |checksum:…,ruby:~> 4.0.0,rubygems:>= 4.1.0.dev,platform:= x86_64-linux
```

- The version slot's "platform" (`ef716ba7a6`) is the **content address** =
  `sha256(.gem)[0,10]`. It becomes the gem's `full_name` and download path.
- The `platform:` **metadata token** carries the real platform, used for
  compatibility matching.
- `rubygems:>= 4.1.0.dev` is the gate: this is the RubyGems version
  content-addressable support is assumed to ship in.

## Run it

```bash
# 1. Resolution proof — no compiler/network needed (pure parser + selection)
./dev/content-addressable-v1-demo/test_resolution.sh

# 2. Local install path — build a native gem, gem install, bundle install --local
./dev/content-addressable-v1-demo/test_local.sh

# 3. Remote install path — serve a v1 index from a fake server, bundle install
PORT=8920 ./dev/content-addressable-v1-demo/test_remote_v1.sh

# 4. Old-client compatibility — stock RubyGems/Bundler ignores the skinny rows
PORT=8920 ./dev/content-addressable-v1-demo/test_remote_v1_oldclient.sh
```

Each ends with `ALL GOOD`. `test_local.sh` / `test_remote_v1.sh` build a tiny
native gem (`demo/`) and need a C toolchain plus a one-time `rake-compiler`
install. They use the Ruby on your `PATH` (the demo gemspec pins `~>` that
Ruby's minor, so it is "skinny" for whatever Ruby you run); override with
`RUBY_PREFIX=/opt/rubies/X`.

## What it proves

### Resolution (`test_resolution.sh`)

For a single `hola 1.0.0` published as **source**, **fat** (regular
precompiled), and **skinny** (content-addressable) variants, using the *real*
client code (`Gem::Resolver::APISet::GemParser`, `Bundler::EndpointSpecification`
built exactly like `Bundler::Fetcher#specs`, and
`Bundler::MatchPlatform.select_best_platform_match`):

1. **New client picks the skinny one** and its download name reconstructs to
   `hola-1.0.0-ef716ba7a6.gem`.
2. **Old client ignores the skinny rows.** The `rubygems:>= 4.1.0.dev`
   requirement is not satisfied by a pre-CA RubyGems (e.g. 3.5.0), so
   `matches_current_rubygems?` is false and the row is dropped; the old client
   falls back to the fat binary.

### Install paths (`test_local.sh`, `test_remote_v1.sh`)

These exercise the install machinery ported from
[PR #168](https://github.com/Shopify/rubygems/pull/168) on top of the v1 branch:

- **Build:** `rake native gem` content-addresses the skinny gem, renaming
  `hola-1.0.0-<platform>.gem` → `hola-1.0.0-<sha>.gem` in `Gem::Package.build`.
- **`--local`:** `gem install` installs under `gems/hola-1.0.0-<sha>/` and
  records the sha in the stub line (`# stub: hola 1.0.0 <platform> lib <sha>`),
  so `full_name` reconstructs the content-addressed name offline.
  `bundle install --local` resolves it (the lockfile stays portable —
  `hola (1.0.0-<platform>)` — and Bundler bridges back to the on-disk
  `name-version-<sha>` gem), `bundle exec require` + `bundle list` work, and
  re-install is idempotent.
- **Remote (v1):** Bundler fetches `/versions` and `/info/hola` (unprefixed —
  **no `/v2/` endpoint**), selects the skinny variant, downloads
  `/gems/hola-1.0.0-<sha>.gem`, installs it, and `require` works.

### Old-client compatibility (`test_remote_v1_oldclient.sh`)

The most important backwards-compat guarantee: a **new publisher** serving
content-addressable gems must not break **old consumers**. This test serves a
real fat binary plus a gated skinny row, then installs with two clients against
the same v1 index:

- **Old client** (the stock RubyGems/Bundler on `PATH` — here 4.0.10, older than
  the `4.1.0.dev` gate and without the patches): ignores the skinny row
  (`rubygems:>= 4.1.0.dev` is unsatisfied, and the `<sha>` token doesn't match
  the local platform anyway), installs `hola-1.0.0-<platform>.gem`, and
  `require` works. It **never requests** the skinny `.gem`, and doesn't choke on
  the `<sha>` version token or the `platform:` metadata token.
- **New client** (patched): selects and downloads the skinny
  `hola-1.0.0-<sha>.gem`.

The server request log shows exactly which `.gem` each client fetched, proving
the split.

## Client changes that make this work (vs. master)

All on top of `master`; **no v2 endpoint involved**. Naming convention on this
branch: the sha identity is `version_suffix`; the real platform from metadata is
`platform_requirement`.

### RubyGems core (build + install)

| File | Change |
| --- | --- |
| `lib/rubygems/platform.rb` | Preserve a 10-hex-char **version suffix** verbatim instead of normalizing it to `os="unknown"`. Kept in its own `version_suffix` field; `==`/`hash`/`===` treat it as an exact-match token. |
| `lib/rubygems/specification.rb` | `content_addressable?` / `content_addressable_ruby_abi` (skinny detection: `~> X.Y.Z` and rake-compiler's `>= X.Y, < X.(Y+1).dev`); `to_ruby` writes the version suffix into the stub line. |
| `lib/rubygems/package.rb` | `Gem::Package.build` renames skinny gems to `name-version-<sha>.gem`. |
| `lib/rubygems/package_task.rb` | Move the (renamed) built file to the package dir. |
| `lib/rubygems/basic_specification.rb` | `version_suffix` accessor; `full_name` returns `name-version-<sha>` when set. |
| `lib/rubygems/stub_specification.rb` | Read the optional 5th stub-line field (the sha); `full_name` reconstructs the content-addressed name; `to_spec` carries the suffix onto the loaded full spec. |
| `lib/rubygems/installer.rb` | `assign_version_suffix` derives the sha from the gem's bytes before any path is computed. |

### Bundler (resolution + install bridge)

| File | Change |
| --- | --- |
| `bundler/lib/bundler/endpoint_specification.rb` | Parse the `platform:` metadata token into `platform_requirement`; add `content_addressable?`, `version_suffix`, and a platform match that uses the platform requirement. |
| `bundler/lib/bundler/match_platform.rb` | When a skinny variant compatible with the running Ruby exists, prefer it **exclusively** over fat/source (per-Ruby-minor `~>` ranges are disjoint, so at most one qualifies). |
| `bundler/lib/bundler/lazy_specification.rb` | Carry `platform_requirement`/`version_suffix`; reconstruct `full_name` as `name-version-<sha>`; on a `--local` exact-match miss, retry by name+version so the portable lockfile entry resolves to the on-disk `name-version-<sha>` gem. |
| `bundler/lib/bundler/stub_specification.rb` | Delegate `full_name`/`version_suffix` to the underlying RubyGems stub. |

## Differences from PR #168

- **No v2 endpoint.** PR #168 negotiates a `/v2/` compact-index namespace to hide
  content-addressable entries from old clients. This branch keeps everything in
  the **v1** index and hides skinny rows from old clients with a `rubygems:>=`
  gate instead, so `compact_index_client.rb` / `cache.rb` /
  `fetcher/compact_index.rb` are left untouched.
- **Naming.** PR #168 uses `content_address` / `real_platform`; this branch uses
  `version_suffix` / `platform_requirement`.

## Known nuance

On the **remote** path the gem currently installs into
`gems/hola-1.0.0-<real-platform>/`, whereas the **`--local`** path installs into
`gems/hola-1.0.0-<sha>/`. Both are internally consistent and work for a single
active Ruby, but they disagree on the on-disk directory name (same nuance noted
in PR #168).
