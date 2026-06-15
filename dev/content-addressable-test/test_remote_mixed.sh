#!/usr/bin/env bash
#
# End-to-end test of a single Gemfile that resolves across a v2 source and a v1
# source at the same time:
#
#     source "http://127.0.0.1:<v2>"        # content-addressable (skinny) hola
#     gem "hola"
#
#     source "http://127.0.0.1:<v1>" do     # legacy v1-only source (saludo)
#       gem "saludo"
#     end
#
# Two fake servers run side by side. The v2 server serves `/v2/versions` +
# `/v2/info/hola` (content-addressed tokens). The v1 server serves ONLY the
# unprefixed `/versions` + `/info/saludo` and 404s the `/v2/versions` probe.
#
# Proves the per-source API negotiation: in one `bundle install` the client
# speaks v2 to the first source (downloads hola-1.0.0-<sha>.gem) and downgrades
# to v1 for the second (downloads saludo-1.0.0.gem), with no cross-source
# leakage. Both gems install and `require`.
#
# Override the ruby with: RUBY_PREFIX=/opt/rubies/3.3.x ./test_remote_mixed.sh
set -euo pipefail

RUBY_PREFIX="${RUBY_PREFIX:-/opt/rubies/3.3.5}"
HERE="$(cd "$(dirname "$0")" && pwd)"
RG="$(cd "$HERE/../.." && pwd)"
DEMO="$HERE/demo"
WORK=/tmp/ca-remote-mixed
PORT_V2="${PORT_V2:-8911}"
PORT_V1="${PORT_V1:-8912}"

export PATH="$RUBY_PREFIX/bin:$PATH"
export GEM_HOME="$WORK/gemhome" GEM_PATH="$WORK/gemhome"
RUBY="$RUBY_PREFIX/bin/ruby"
BUNDLE="$RUBY -I$RG/bundler/lib $RG/bundler/exe/bundle"

rm -rf "$WORK"
mkdir -p "$WORK/gemhome" "$WORK/app" \
         "$WORK/srv_v2/gems" "$WORK/srv_v2/v2/info" \
         "$WORK/srv_v1/gems" "$WORK/srv_v1/info" \
         "$WORK/saludo/lib"
echo "ruby: $($RUBY -e 'print RUBY_VERSION, " ", RUBY_PLATFORM')"

echo "== install released rake-compiler + build content-addressed gem (hola) =="
$RUBY -S gem install rake-compiler --no-document >/dev/null
cd "$DEMO"; rm -rf tmp pkg lib/hola/*.bundle lib/hola/*.so
RUBYOPT="--disable-gems -I$RG/lib -rrubygems" $RUBY -S rake native gem 2>&1 | grep -E "Content-addressed"
HOLA=$(ls pkg/hola-1.0.0-*.gem)
cp "$HOLA" "$WORK/srv_v2/gems/"
echo "   v2 gem: $(basename "$HOLA")"

echo "== build a plain pure-ruby gem (saludo) for the v1 source =="
cat > "$WORK/saludo/saludo.gemspec" <<'GEMSPEC'
Gem::Specification.new do |s|
  s.name        = "saludo"
  s.version     = "1.0.0"
  s.summary     = "plain pure-ruby gem served from a v1-only source"
  s.authors     = ["poc"]
  s.files       = Dir["lib/**/*.rb"]
end
GEMSPEC
cat > "$WORK/saludo/lib/saludo.rb" <<'RB'
def saludo
  "hola from saludo (v1 source)"
end
RB
( cd "$WORK/saludo" && RUBYOPT="--disable-gems -I$RG/lib -rrubygems" $RUBY -S gem build saludo.gemspec >/dev/null )
SALUDO=$(ls "$WORK/saludo"/saludo-1.0.0.gem)
cp "$SALUDO" "$WORK/srv_v1/gems/"
echo "   v1 gem: $(basename "$SALUDO")"

echo "== render a v2 index for hola and a v1 index for saludo =="
RUBYOPT="--disable-gems -I$RG/lib -rrubygems" $RUBY - \
  "$HOLA" "$WORK/srv_v2" "$SALUDO" "$WORK/srv_v1" <<'RUBY'
require "rubygems/package"
require "digest"

hola_gem, v2, saludo_gem, v1 = ARGV

# --- v2 source: content-addressable hola, served under /v2/ -----------------
spec   = Gem::Package.new(hola_gem).spec
sha256 = Digest::SHA256.hexdigest(File.binread(hola_gem))
addr   = sha256[0, 10]
real   = spec.platform.to_s
ruby   = spec.required_ruby_version.as_list.join("&")
info = +"---\n"
info << "#{spec.version}-#{addr} |checksum:#{sha256},ruby:#{ruby},platform:#{real}\n"
File.write(File.join(v2, "v2/info/hola"), info)
versions = +"created_at: 2024-01-01T00:00:00Z\n---\n"
versions << "hola #{spec.version}-#{addr} #{Digest::MD5.hexdigest(info)}\n"
File.write(File.join(v2, "v2/versions"), versions)
warn "   [v2] /v2/info/hola: #{info.lines.last.chomp}"

# --- v1 source: plain saludo, UNPREFIXED (no /v2/, no <sha> token) ----------
sspec   = Gem::Package.new(saludo_gem).spec
ssha256 = Digest::SHA256.hexdigest(File.binread(saludo_gem))
sinfo = +"---\n"
sinfo << "#{sspec.version} |checksum:#{ssha256}\n"
File.write(File.join(v1, "info/saludo"), sinfo)
sversions = +"created_at: 2024-01-01T00:00:00Z\n---\n"
sversions << "saludo #{sspec.version} #{Digest::MD5.hexdigest(sinfo)}\n"
File.write(File.join(v1, "versions"), sversions)
warn "   [v1] /info/saludo: #{sinfo.lines.last.chomp}"
RUBY

# IMPORTANT: bundle must load the PATCHED rubygems core (content-addressable
# Gem::Platform), not Ruby's built-in rubygems.
export RUBYOPT="--disable-gems -I$RG/lib -rrubygems"

echo "== start two fake servers: v2 source + v1-only source =="
$RUBY "$HERE/fake_compact_index.rb" "$WORK/srv_v2" "$PORT_V2" 2>"$WORK/srv_v2.log" &
SRV_V2=$!
$RUBY "$HERE/fake_compact_index.rb" "$WORK/srv_v1" "$PORT_V1" 2>"$WORK/srv_v1.log" &
SRV_V1=$!
trap 'kill $SRV_V2 $SRV_V1 2>/dev/null || true' EXIT
sleep 1

echo "== bundle install (one Gemfile: v2 source + scoped v1 source) =="
cd "$WORK/app"
cat > Gemfile <<GEMFILE
source "http://127.0.0.1:$PORT_V2"
gem "hola"

source "http://127.0.0.1:$PORT_V1" do
  gem "saludo"
end
GEMFILE
$BUNDLE install 2>&1 | grep -iE "fetching|installing|complete|could not|error" || true
echo "   installed hola  : $(basename "$(ls -d "$GEM_HOME"/gems/hola-*   2>/dev/null)")"
echo "   installed saludo: $(basename "$(ls -d "$GEM_HOME"/gems/saludo-* 2>/dev/null)")"

echo "== assert per-source API negotiation =="
if grep -q "GET /v2/info/hola -> 200" "$WORK/srv_v2.log" && grep -q "GET /gems/hola-1.0.0-" "$WORK/srv_v2.log"; then
  echo "   OK: v2 source served /v2/info/hola + content-addressed gem"
else
  echo "   FAIL: v2 source did not serve hola over v2"; exit 1
fi
if grep -q "GET /v2/versions -> 404" "$WORK/srv_v1.log" && grep -q "GET /info/saludo -> 200" "$WORK/srv_v1.log"; then
  echo "   OK: v1 source 404'd the /v2 probe and served /info/saludo over v1"
else
  echo "   FAIL: v1 source did not downgrade as expected"; exit 1
fi
if grep -q "GET /v2/info/saludo" "$WORK/srv_v1.log"; then
  echo "   FAIL: client requested a /v2/info entry on the v1-only source"; exit 1
else
  echo "   OK: no /v2/info request on the v1 source"
fi

echo "== bundle exec require (both gems) =="
$BUNDLE exec ruby -e 'require "hola"; require "saludo"; puts "   => " + hola + " | " + saludo'

echo "== lockfile =="
grep -nE "remote:|hola|saludo" Gemfile.lock | sed 's/^/   /'

echo
echo "== v2 server request log =="
sed 's/^/   [v2] /' "$WORK/srv_v2.log"
echo "== v1 server request log =="
sed 's/^/   [v1] /' "$WORK/srv_v1.log"
echo "ALL GOOD"
