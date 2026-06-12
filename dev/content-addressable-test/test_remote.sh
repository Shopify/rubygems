#!/usr/bin/env bash
#
# End-to-end test of a content-addressable ("skinny") gem over the REMOTE path:
# Bundler resolves and downloads it from a fake compact-index server. No
# rubygems.org, no containers.
#
# Proves: Bundler probes /v2/versions, parses the content-addressed info line
# (version slot = <sha>, platform: token = real platform), downloads
# /gems/hola-1.0.0-<sha>.gem, installs it, and `require` works.
#
# Override the ruby with: RUBY_PREFIX=/opt/rubies/3.3.x ./test_remote.sh
set -euo pipefail

RUBY_PREFIX="${RUBY_PREFIX:-/opt/rubies/3.3.5}"
HERE="$(cd "$(dirname "$0")" && pwd)"
RG="$(cd "$HERE/../.." && pwd)"
DEMO="$HERE/demo"
WORK=/tmp/ca-remote
PORT="${PORT:-8899}"

export PATH="$RUBY_PREFIX/bin:$PATH"
export GEM_HOME="$WORK/gemhome" GEM_PATH="$WORK/gemhome"
RUBY="$RUBY_PREFIX/bin/ruby"
BUNDLE="$RUBY -I$RG/bundler/lib $RG/bundler/exe/bundle"

rm -rf "$WORK"; mkdir -p "$WORK/gemhome" "$WORK/app" "$WORK/srv/gems" "$WORK/srv/v2/info"
echo "ruby: $($RUBY -e 'print RUBY_VERSION, " ", RUBY_PLATFORM')"

echo "== install released rake-compiler + build content-addressed gem =="
$RUBY -S gem install rake-compiler --no-document >/dev/null
cd "$DEMO"; rm -rf tmp pkg lib/hola/*.bundle lib/hola/*.so
RUBYOPT="--disable-gems -I$RG/lib -rrubygems" $RUBY -S rake native gem 2>&1 | grep -E "Content-addressed"
GEM=$(ls pkg/hola-1.0.0-*.gem)
cp "$GEM" "$WORK/srv/gems/"
echo "   gem: $(basename "$GEM")"

echo "== render compact-index files from the gem =="
RUBYOPT="--disable-gems -I$RG/lib -rrubygems" $RUBY - "$GEM" "$WORK/srv" <<'RUBY'
require "rubygems/package"
require "digest"
gemfile, srv = ARGV
spec   = Gem::Package.new(gemfile).spec
sha256 = Digest::SHA256.hexdigest(File.binread(gemfile))
addr   = sha256[0, 10]                                  # content address == sha in the filename
real   = spec.platform.to_s                             # e.g. arm64-darwin-23
ruby   = spec.required_ruby_version.as_list.join("&")   # e.g. "~> 3.3.0"

# info line: "<version>-<sha> |checksum:<sha256>,ruby:<req>,platform:<real>"
info = +"---\n"
info << "#{spec.version}-#{addr} |checksum:#{sha256},ruby:#{ruby},platform:#{real}\n"
File.write(File.join(srv, "v2/info/hola"), info)

# versions line: "<name> <version>-<sha> <md5-of-info>"
versions = +"created_at: 2024-01-01T00:00:00Z\n---\n"
versions << "hola #{spec.version}-#{addr} #{Digest::MD5.hexdigest(info)}\n"
File.write(File.join(srv, "v2/versions"), versions)

warn "   filename sha == sha256[0,10]? #{File.basename(gemfile).include?(addr)}"
warn "   /v2/info/hola: #{info.lines.last.chomp}"
RUBY

# IMPORTANT: bundle must load the PATCHED rubygems core (content-addressable
# Gem::Platform), not Ruby's built-in rubygems, or the <sha> platform token
# normalizes to "unknown".
export RUBYOPT="--disable-gems -I$RG/lib -rrubygems"

echo "== start fake compact-index server =="
$RUBY "$HERE/fake_compact_index.rb" "$WORK/srv" "$PORT" 2>"$WORK/srv.log" &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 1

echo "== bundle install (REMOTE, from fake server) =="
cd "$WORK/app"
printf 'source "http://127.0.0.1:%s"\ngem "hola"\n' "$PORT" > Gemfile
$BUNDLE install 2>&1 | grep -iE "fetching|installing|complete|could not|error" || true
echo "   installed: $(basename "$(ls -d "$GEM_HOME"/gems/hola-* 2>/dev/null)")"

echo "== bundle exec require =="
$BUNDLE exec ruby -e 'require "hola"; puts "   => " + hola'

echo
echo "== server request log =="
sed 's/^/   /' "$WORK/srv.log"
echo "ALL GOOD"
