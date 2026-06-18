#!/usr/bin/env bash
#
# End-to-end test of content-addressable ("skinny") precompiled gems over the
# LOCAL path (bundle install --local), natively. No containers, no network
# except the one-time rake-compiler install.
#
# Proves the install paths from PR #168 on top of the v1 branch:
#   - `rake native gem` builds a skinny gem and renames it to name-version-<sha>.gem
#   - `gem install` installs it under gems/name-version-<sha>/ with the sha in the stub
#   - `bundle install --local` resolves the content-addressed gem (lockfile round-trip)
#   - `bundle exec require` + `bundle list` work; re-install is idempotent
#
# Uses the Ruby on your PATH (the demo gemspec pins ~> that Ruby's minor, so it
# is skinny for whatever Ruby you run). Override with RUBY_PREFIX=/opt/rubies/X.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RG="$(cd "$HERE/../.." && pwd)"                    # this rubygems checkout (patched)
DEMO="$HERE/demo"
WORK=/tmp/ca-v1-local

if [ -n "${RUBY_PREFIX:-}" ]; then export PATH="$RUBY_PREFIX/bin:$PATH"; fi
RUBY="$(command -v ruby)"
export GEM_HOME="$WORK/gemhome" GEM_PATH="$WORK/gemhome"
BUNDLE="$RUBY -I$RG/bundler/lib $RG/bundler/exe/bundle"

rm -rf "$WORK"; mkdir -p "$WORK/gemhome" "$WORK/app"
echo "ruby: $($RUBY -e 'print RUBY_VERSION, " ", RUBY_PLATFORM')"

echo "== install released rake-compiler (clean RubyGems) =="
$RUBY -S gem install rake-compiler --no-document >/dev/null

echo "== build native gem (patched RubyGems loaded over installed gems) =="
cd "$DEMO"; rm -rf tmp pkg lib/hola/*.bundle lib/hola/*.so
RUBYOPT="--disable-gems -I$RG/lib -rrubygems" $RUBY -S rake native gem 2>&1 | grep -E "File|Content-addressed"
GEM=$(ls pkg/hola-1.0.0-*.gem)
echo "   built       : $(basename "$GEM")"

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
