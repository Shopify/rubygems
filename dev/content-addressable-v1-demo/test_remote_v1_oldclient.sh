#!/usr/bin/env bash
#
# Backwards-compatibility test: an OLD client (stock RubyGems/Bundler, WITHOUT
# the content-addressable patches and with a RubyGems version older than the
# `rubygems:>= 4.1.0.dev` gate) must transparently ignore the skinny rows in a
# v1 compact index and install the ordinary fat binary instead.
#
# The publisher/registry is "new" (gems built with the patched RubyGems), but
# the consumer is "old". This is the exact upgrade ordering the proposal relies
# on (ship the consuming side first, then publish content-addressable gems).
#
# Proves:
#   - the old client never requests /gems/hola-1.0.0-<sha>.gem (the skinny gem)
#   - it installs the fat hola-1.0.0-<platform>.gem and `require` works
#   - no crash/parse error on the skinny row's <sha> version token or its
#     `platform:` metadata token
#
# Then re-runs with the NEW (patched) client to show it DOES pick the skinny one.
set -euo pipefail

CA_SUPPORTED_FROM="4.1.0.dev"
HERE="$(cd "$(dirname "$0")" && pwd)"
RG="$(cd "$HERE/../.." && pwd)"
DEMO="$HERE/demo"
WORK=/tmp/ca-v1-oldclient
PORT="${PORT:-8899}"

if [ -n "${RUBY_PREFIX:-}" ]; then export PATH="$RUBY_PREFIX/bin:$PATH"; fi
RUBY="$(command -v ruby)"

rm -rf "$WORK"; mkdir -p "$WORK/srv/gems" "$WORK/srv/info" "$WORK/app-old" "$WORK/app-new"
# Clean GEM_HOME/GEM_PATH so the stock client doesn't load ABI-mismatched native
# gems from ~/.gem (which would crash, unrelated to this feature).
export GEM_HOME="$WORK/buildhome" GEM_PATH="$WORK/buildhome"
echo "ruby: $($RUBY -e 'print RUBY_VERSION, " ", RUBY_PLATFORM')"
echo "stock client: RubyGems $($RUBY -e 'puts Gem::VERSION'), Bundler $($RUBY -e 'require "bundler"; puts Bundler::VERSION')"

echo
echo "== install released rake-compiler =="
$RUBY -S gem install rake-compiler --no-document >/dev/null

SRC="$WORK/build"
rm -rf "$SRC"; cp -R "$DEMO" "$SRC"; rm -rf "$SRC/tmp" "$SRC/pkg" "$SRC"/lib/hola/*.bundle "$SRC"/lib/hola/*.so
MINOR="$($RUBY -e 'print RUBY_VERSION.split(".").first(2).join(".")')"
PLATFORM="$($RUBY -e 'print Gem::Platform.local.to_s')"

echo "== build SKINNY binary: rake native gem =="
echo "   (rake-compiler pins required_ruby_version to a single ABI -> content-addressable)"
( cd "$SRC" && RUBYOPT="--disable-gems -I$RG/lib -rrubygems" $RUBY -S rake native gem 2>&1 | grep -E "Content-addressed" )
SKINNY="$(ls "$SRC"/pkg/hola-1.0.0-*.gem)"
echo "   $(basename "$SKINNY")"

echo "== build FAT binary: repackage the compiled .bundle with ruby >= 2.7 =="
echo "   (spans many ABIs -> NOT content-addressable, keeps name-version-platform)"
# Reuse the just-compiled native lib so `require` works on this Ruby, but give it
# a broad required_ruby_version and an explicit platform so it is a plain fat
# binary, bypassing rake-compiler's single-ABI pinning.
cat > "$SRC/fat.gemspec" <<GEMSPEC
Gem::Specification.new do |s|
  s.name        = "hola"
  s.version     = "1.0.0"
  s.summary     = "content-addressable native gem demo (fat)"
  s.authors     = ["poc"]
  s.platform    = "$PLATFORM"
  s.files       = Dir["lib/**/*.rb"] + Dir["lib/**/*.bundle"] + Dir["lib/**/*.so"]
  s.required_ruby_version = ">= 2.7"
end
GEMSPEC
( cd "$SRC" && RUBYOPT="--disable-gems -I$RG/lib -rrubygems" $RUBY -S gem build fat.gemspec 2>&1 | grep -iE "file:|warning" || true )
FAT="$(ls "$SRC"/hola-1.0.0-*.gem | grep -v -- "-pkg" | head -1)"
echo "   $(basename "$FAT")"

cp "$FAT" "$SKINNY" "$WORK/srv/gems/"

echo "== render v1 /info/hola (fat ungated + skinny gated) =="
RUBYOPT="--disable-gems -I$RG/lib -rrubygems" $RUBY - "$FAT" "$SKINNY" "$WORK/srv" "$CA_SUPPORTED_FROM" <<'RUBY'
require "rubygems/package"
require "digest"
fat, skinny, srv, gate = ARGV
fspec = Gem::Package.new(fat).spec
fsha  = Digest::SHA256.hexdigest(File.binread(fat))
ssha  = Digest::SHA256.hexdigest(File.binread(skinny))
addr  = ssha[0, 10]
real  = fspec.platform.to_s
sruby = Gem::Package.new(skinny).spec.required_ruby_version.as_list.join("&")

info  = +"---\n"
info << "1.0.0-#{real} |checksum:#{fsha},ruby:>= 2.7\n"
info << "1.0.0-#{addr} |checksum:#{ssha},ruby:#{sruby},rubygems:>= #{gate},platform:= #{real}\n"
File.write(File.join(srv, "info/hola"), info)

versions = +"created_at: 2024-01-01T00:00:00Z\n---\n"
versions << "hola 1.0.0-#{real},1.0.0-#{addr} #{Digest::MD5.hexdigest(info)}\n"
File.write(File.join(srv, "versions"), versions)

File.write(File.join(srv, "addr.txt"), addr)   # so the shell knows the skinny filename
info.lines.drop(1).each {|l| warn "   /info/hola: #{l.chomp}" }
RUBY
ADDR="$(cat "$WORK/srv/addr.txt")"

echo
echo "== start fake v1 compact-index server =="
$RUBY "$HERE/fake_compact_index.rb" "$WORK/srv" "$PORT" 2>"$WORK/srv.log" &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 1

# ---------------------------------------------------------------------------
# OLD CLIENT: stock RubyGems + Bundler, no patches. Must ignore the skinny row.
# ---------------------------------------------------------------------------
echo
echo "########## OLD CLIENT (stock RubyGems $($RUBY -e 'puts Gem::VERSION')) ##########"
cd "$WORK/app-old"
export GEM_HOME="$WORK/old-gemhome" GEM_PATH="$WORK/old-gemhome"
unset RUBYOPT   # <-- do NOT load the patched rubygems/bundler
printf 'source "http://127.0.0.1:%s"\ngem "hola"\n' "$PORT" > Gemfile
$RUBY -S bundle install 2>&1 | grep -iE "fetching|installing|complete|could not|error" || true
echo "   installed: $(basename "$(ls -d "$GEM_HOME"/gems/hola-* 2>/dev/null)")"
$RUBY -S bundle exec ruby -e 'require "hola"; puts "   => " + hola'

if grep -q "GET /gems/hola-1.0.0-${ADDR}.gem" "$WORK/srv.log"; then
  echo "FAIL: old client requested the SKINNY gem (hola-1.0.0-${ADDR}.gem)"; exit 1
fi
echo "   [check] old client never requested the skinny gem (hola-1.0.0-${ADDR}.gem) -> OK"

# ---------------------------------------------------------------------------
# NEW CLIENT: patched RubyGems + Bundler. Must pick the skinny row.
# ---------------------------------------------------------------------------
echo
echo "########## NEW CLIENT (patched RubyGems 4.1.0.dev) ##########"
cd "$WORK/app-new"
export GEM_HOME="$WORK/new-gemhome" GEM_PATH="$WORK/new-gemhome"
export RUBYOPT="--disable-gems -I$RG/lib -rrubygems"
printf 'source "http://127.0.0.1:%s"\ngem "hola"\n' "$PORT" > Gemfile
$RUBY -I"$RG/bundler/lib" "$RG/bundler/exe/bundle" install 2>&1 | grep -iE "fetching|installing|complete|could not|error" || true
$RUBY -I"$RG/bundler/lib" "$RG/bundler/exe/bundle" exec ruby -e 'require "hola"; puts "   => " + hola'
if grep -q "GET /gems/hola-1.0.0-${ADDR}.gem" "$WORK/srv.log"; then
  echo "   [check] new client requested the skinny gem (hola-1.0.0-${ADDR}.gem) -> OK"
else
  echo "FAIL: new client did NOT request the skinny gem"; exit 1
fi

echo
echo "== server request log (/gems only) =="
grep "GET /gems/" "$WORK/srv.log" | sed 's/^/   /'
echo "ALL GOOD"
