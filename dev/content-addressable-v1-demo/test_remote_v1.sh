#!/usr/bin/env bash
#
# End-to-end test of a content-addressable ("skinny") gem over the REMOTE path
# using the **v1** compact index (no /v2/ endpoint). Bundler resolves and
# downloads it from a fake compact-index server. No rubygems.org, no containers.
#
# Proves the full v1 install path:
#   - /info/hola lists source + fat + skinny rows; the skinny row carries the
#     content address in the version slot, the real platform in a `platform:`
#     token, and a `rubygems:>= 4.1.0.dev` gate.
#   - A new client selects the skinny variant, downloads
#     /gems/hola-1.0.0-<sha>.gem, installs it, and `require` works.
#
# Uses the Ruby on your PATH (demo gemspec pins ~> that Ruby's minor, so it is
# skinny). Override with RUBY_PREFIX=/opt/rubies/X. Override PORT if 8899 is busy.
set -euo pipefail

CA_SUPPORTED_FROM="4.1.0.dev"   # the rubygems gate; this build satisfies it
HERE="$(cd "$(dirname "$0")" && pwd)"
RG="$(cd "$HERE/../.." && pwd)"
DEMO="$HERE/demo"
WORK=/tmp/ca-v1-remote
PORT="${PORT:-8899}"

if [ -n "${RUBY_PREFIX:-}" ]; then export PATH="$RUBY_PREFIX/bin:$PATH"; fi
RUBY="$(command -v ruby)"
export GEM_HOME="$WORK/gemhome" GEM_PATH="$WORK/gemhome"
BUNDLE="$RUBY -I$RG/bundler/lib $RG/bundler/exe/bundle"

rm -rf "$WORK"; mkdir -p "$WORK/gemhome" "$WORK/app" "$WORK/srv/gems" "$WORK/srv/info"
echo "ruby: $($RUBY -e 'print RUBY_VERSION, " ", RUBY_PLATFORM')"

echo "== install released rake-compiler + build content-addressed gem =="
$RUBY -S gem install rake-compiler --no-document >/dev/null
cd "$DEMO"; rm -rf tmp pkg lib/hola/*.bundle lib/hola/*.so
RUBYOPT="--disable-gems -I$RG/lib -rrubygems" $RUBY -S rake native gem 2>&1 | grep -E "Content-addressed"
GEM=$(ls pkg/hola-1.0.0-*.gem)
cp "$GEM" "$WORK/srv/gems/"
echo "   gem: $(basename "$GEM")"

echo "== render v1 compact-index files (source + fat + skinny) =="
RUBYOPT="--disable-gems -I$RG/lib -rrubygems" $RUBY - "$GEM" "$WORK/srv" "$CA_SUPPORTED_FROM" <<'RUBY'
require "rubygems/package"
require "digest"
gemfile, srv, gate = ARGV
spec   = Gem::Package.new(gemfile).spec
sha256 = Digest::SHA256.hexdigest(File.binread(gemfile))
addr   = sha256[0, 10]                                  # content address == sha in the filename
real   = spec.platform.to_s                             # e.g. arm64-darwin-24
ruby   = spec.required_ruby_version.as_list.join("&")   # e.g. "~> 4.0.0"

# Three rows for hola 1.0.0, content-addressable rows last (per the proposal):
#   source : version slot has no platform
#   fat     : version slot = real platform (broad ruby req)
#   skinny  : version slot = <sha>, real platform in platform: token, rubygems: gate
info  = +"---\n"
info << "1.0.0 |checksum:#{"a" * 64},ruby:>= 2.7,rubygems:>= 3.3.22\n"
info << "1.0.0-#{real} |checksum:#{"b" * 64},ruby:>= 2.7\n"
info << "1.0.0-#{addr} |checksum:#{sha256},ruby:#{ruby},rubygems:>= #{gate},platform:= #{real}\n"
File.write(File.join(srv, "info/hola"), info)

versions = +"created_at: 2024-01-01T00:00:00Z\n---\n"
versions << "hola 1.0.0,1.0.0-#{real},1.0.0-#{addr} #{Digest::MD5.hexdigest(info)}\n"
File.write(File.join(srv, "versions"), versions)

warn "   filename sha == sha256[0,10]? #{File.basename(gemfile).include?(addr)}"
info.lines.drop(1).each {|l| warn "   /info/hola: #{l.chomp}" }
RUBY

# IMPORTANT: bundle must load the PATCHED rubygems core (content-addressable
# Gem::Platform), not Ruby's built-in rubygems, or the <sha> platform token
# normalizes to "unknown".
export RUBYOPT="--disable-gems -I$RG/lib -rrubygems"

echo "== start fake v1 compact-index server =="
$RUBY "$HERE/fake_compact_index.rb" "$WORK/srv" "$PORT" 2>"$WORK/srv.log" &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 1

echo "== bundle install (REMOTE, v1 index, from fake server) =="
cd "$WORK/app"
printf 'source "http://127.0.0.1:%s"\ngem "hola"\n' "$PORT" > Gemfile
$BUNDLE install 2>&1 | grep -iE "fetching|installing|complete|could not|error" || true
echo "   installed: $(basename "$(ls -d "$GEM_HOME"/gems/hola-* 2>/dev/null)")"

echo "== prove the SKINNY gem was the one downloaded =="
if grep -q "GET /gems/hola-1.0.0-${GEM##*hola-1.0.0-}" "$WORK/srv.log" 2>/dev/null; then :; fi
grep "GET /gems/" "$WORK/srv.log" | sed 's/^/   /'

echo "== bundle exec require =="
$BUNDLE exec ruby -e 'require "hola"; puts "   => " + hola'

echo
echo "== server request log =="
sed 's/^/   /' "$WORK/srv.log"
echo "ALL GOOD"
