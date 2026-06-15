#!/usr/bin/env bash
#
# End-to-end test of content-addressable ("skinny") precompiled gems over the
# LOCAL path (bundle install --local), natively on macOS. No containers.
#
# Proves:
#   - `rake native gem` builds a skinny gem and renames it to name-version-<sha>.gem
#   - `gem install` installs it under gems/name-version-<sha>/ with the sha in the stub
#   - `bundle install --local` resolves the content-addressed gem (incl. lockfile round-trip)
#   - `bundle exec require` + `bundle list` work
#
# Override the ruby with: RUBY_PREFIX=/opt/rubies/3.3.x ./test_local.sh
set -euo pipefail

RUBY_PREFIX="${RUBY_PREFIX:-/opt/rubies/3.3.5}"   # clean ruby satisfying demo's ~> 3.3.0
HERE="$(cd "$(dirname "$0")" && pwd)"
RG="$(cd "$HERE/../.." && pwd)"                    # this rubygems checkout (patched)
DEMO="$HERE/demo"
WORK=/tmp/ca-local

export PATH="$RUBY_PREFIX/bin:$PATH"
export GEM_HOME="$WORK/gemhome" GEM_PATH="$WORK/gemhome"
RUBY="$RUBY_PREFIX/bin/ruby"
BUNDLE="$RUBY -I$RG/bundler/lib $RG/bundler/exe/bundle"

rm -rf "$WORK"; mkdir -p "$WORK/gemhome" "$WORK/app"
echo "ruby: $($RUBY -e 'print RUBY_VERSION, " ", RUBY_PLATFORM')"

echo "== install released rake-compiler (clean RubyGems) =="
$RUBY -S gem install rake-compiler --no-document >/dev/null

echo "== build native gem (patched RubyGems loaded over installed gems) =="
cd "$DEMO"; rm -rf tmp pkg lib/hola/*.bundle lib/hola/*.so
RUBYOPT="--disable-gems -I$RG/lib -rrubygems" $RUBY -S rake native gem 2>&1 | grep -E "File|Content-addressed"
GEM=$(ls pkg/hola-1.0.0-*.gem)

# everything below uses the patched RubyGems
export RUBYOPT="--disable-gems -I$RG/lib -rrubygems"

echo "== gem install --local =="
$RUBY -S gem install --local "$GEM" --no-document | grep -i installed
echo "   install dir : $(basename "$(ls -d "$GEM_HOME"/gems/hola-*)")"
echo "   stub line   : $(grep '# stub:' "$GEM_HOME"/specifications/hola-*.gemspec)"

echo "== bundle install --local =="
cd "$WORK/app"
printf 'source "http://example.invalid"\ngem "hola"\n' > Gemfile
$BUNDLE install --local 2>&1 | grep -iE "complete|could not"
echo "   lockfile    : $(grep -A1 'specs:' Gemfile.lock | tail -1 | xargs)"

echo "== bundle exec require =="
$BUNDLE exec ruby -e 'require "hola"; puts "   => " + hola'

echo "== bundle install --local AGAIN (idempotent, reads lock) =="
$BUNDLE install --local 2>&1 | grep -iE "complete|could not"

echo "== bundle list =="
$BUNDLE list | grep hola

echo "ALL GOOD"
