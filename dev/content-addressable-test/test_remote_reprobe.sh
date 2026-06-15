#!/usr/bin/env bash
#
# Regression test for API-version RE-PROBING.
#
# Before: once a source negotiated v1, the persisted `api_version` marker pinned
# it to v1 FOREVER -- a source that later added v2 support was ignored until the
# cache was cleared by hand.
#
# Now: the client re-probes on every resolve (the probe's `versions` fetch is an
# ETag-conditional request, so it's cheap on a warm cache), so an upgrade to v2
# is picked up. The persisted marker is kept only as an offline fallback.
#
# This test:
#   1. Serves a v1-only index, installs -> client negotiates + caches v1.
#   2. Upgrades the SAME source to v2 (adds /v2/*).
#   3. Re-resolves and asserts the client re-probed /v2/versions and switched
#      to v2 (no cache-clearing or marker surgery required).
#
# Override the ruby with: RUBY_PREFIX=/opt/rubies/3.3.x ./test_remote_reprobe.sh
set -euo pipefail

RUBY_PREFIX="${RUBY_PREFIX:-/opt/rubies/3.3.5}"
HERE="$(cd "$(dirname "$0")" && pwd)"
RG="$(cd "$HERE/../.." && pwd)"
DEMO="$HERE/demo"
WORK=/tmp/ca-remote-reprobe
PORT="${PORT_REPROBE:-8921}"

export PATH="$RUBY_PREFIX/bin:$PATH"
export GEM_HOME="$WORK/gemhome" GEM_PATH="$WORK/gemhome"
export BUNDLE_USER_HOME="$WORK/bundle-user"   # isolate compact_index cache under $WORK
RUBY="$RUBY_PREFIX/bin/ruby"
BUNDLE="$RUBY -I$RG/bundler/lib $RG/bundler/exe/bundle"

rm -rf "$WORK"; mkdir -p "$WORK/gemhome" "$WORK/app" "$WORK/srv/gems" "$WORK/srv/info" "$WORK/srv/v2/info"
echo "ruby: $($RUBY -e 'print RUBY_VERSION, " ", RUBY_PLATFORM')"

echo "== build the content-addressed gem (hola) =="
$RUBY -S gem install rake-compiler --no-document >/dev/null
cd "$DEMO"; rm -rf tmp pkg lib/hola/*.bundle lib/hola/*.so
RUBYOPT="--disable-gems -I$RG/lib -rrubygems" $RUBY -S rake native gem 2>&1 | grep -E "Content-addressed"
GEM=$(ls pkg/hola-1.0.0-*.gem)

echo "== render BOTH a v1 index (active now) and a v2 index (added in step 2) =="
RUBYOPT="--disable-gems -I$RG/lib -rrubygems" $RUBY - "$GEM" "$WORK/srv" <<'RUBY'
require "rubygems/package"; require "digest"; require "fileutils"
gemfile, srv = ARGV
spec   = Gem::Package.new(gemfile).spec
sha256 = Digest::SHA256.hexdigest(File.binread(gemfile))
addr   = sha256[0, 10]
real   = spec.platform.to_s
ruby   = spec.required_ruby_version.as_list.join("&")

# v1 (traditional): real platform in version slot, served as hola-1.0.0-<real>.gem
full_v1 = "#{spec.name}-#{spec.version}-#{real}"
FileUtils.cp(gemfile, File.join(srv, "gems", "#{full_v1}.gem"))
info1 = +"---\n#{spec.version}-#{real} |checksum:#{sha256},ruby:#{ruby}\n"
File.write(File.join(srv, "info/hola"), info1)
File.write(File.join(srv, "versions"),
           "created_at: 2024-01-01T00:00:00Z\n---\nhola #{spec.version}-#{real} #{Digest::MD5.hexdigest(info1)}\n")

# v2 (content-addressable): staged under v2/, served as hola-1.0.0-<sha>.gem
FileUtils.cp(gemfile, File.join(srv, "gems", "#{spec.name}-#{spec.version}-#{addr}.gem"))
info2 = +"---\n#{spec.version}-#{addr} |checksum:#{sha256},ruby:#{ruby},platform:#{real}\n"
File.write(File.join(srv, "v2/info/hola"), info2)
File.write(File.join(srv, "v2/versions"),
           "created_at: 2024-01-01T00:00:00Z\n---\nhola #{spec.version}-#{addr} #{Digest::MD5.hexdigest(info2)}\n")
warn "   v1 /info/hola : #{info1.lines.last.chomp}"
warn "   v2 /v2/info/hola: #{info2.lines.last.chomp}"
RUBY

export RUBYOPT="--disable-gems -I$RG/lib -rrubygems"

# ---------------------------------------------------------------------------
echo "== STEP 1: serve v1 ONLY, install -> negotiate + cache v1 =="
mv "$WORK/srv/v2" "$WORK/v2_staged"   # hide v2 so /v2/versions 404s
$RUBY "$HERE/fake_compact_index.rb" "$WORK/srv" "$PORT" 2>"$WORK/srv1.log" & SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 1
cd "$WORK/app"
printf 'source "http://127.0.0.1:%s"\ngem "hola"\n' "$PORT" > Gemfile
$BUNDLE install 2>&1 | grep -iE "installing|complete" || true
MARKER=$(ls "$BUNDLE_USER_HOME"/cache/compact_index/*/api_version)
echo "   cached api_version = $(cat "$MARKER")  (expect 1)"
[ "$(cat "$MARKER")" = "1" ] || { echo "   FAIL: expected v1 to be cached"; exit 1; }
kill $SRV 2>/dev/null || true; sleep 1

# ---------------------------------------------------------------------------
echo "== STEP 2: UPGRADE the same source to v2 (add /v2/*) =="
mv "$WORK/v2_staged" "$WORK/srv/v2"
rm -f Gemfile.lock   # force a fresh resolve against the index
$RUBY "$HERE/fake_compact_index.rb" "$WORK/srv" "$PORT" 2>"$WORK/srv2.log" & SRV=$!
sleep 1

echo "== STEP 3: re-resolve -> client should re-probe and switch to v2 =="
$BUNDLE install 2>&1 | grep -iE "installing|complete|fetching hola" || true
echo "   cached api_version = $(cat "$MARKER")  (expect 2)"

echo "== assertions =="
if grep -q "GET /v2/versions -> 200" "$WORK/srv2.log"; then
  echo "   OK: re-probed /v2/versions after the source upgraded"
else
  echo "   FAIL: client never re-probed /v2 (still pinned to v1)"; exit 1
fi
if [ "$(cat "$MARKER")" = "2" ]; then
  echo "   OK: marker upgraded v1 -> v2"
else
  echo "   FAIL: marker did not upgrade to v2"; exit 1
fi
if grep -q "GET /v2/info/hola -> 200" "$WORK/srv2.log"; then
  echo "   OK: now fetching content-addressed /v2/info/hola"
else
  echo "   FAIL: did not fetch v2 info"; exit 1
fi

echo
echo "== step-1 (v1) request log =="; sed 's/^/   /' "$WORK/srv1.log"
echo "== step-3 (after upgrade) request log =="; sed 's/^/   /' "$WORK/srv2.log"
echo "ALL GOOD"
