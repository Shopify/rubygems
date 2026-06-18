#!/usr/bin/env bash
# Prove that content-addressable ("skinny") gems encoded in the v1 compact
# index are chosen over fat + source variants by a new client, and ignored by
# old clients via the `rubygems:` gate.
#
# Loads the patched RubyGems + Bundler from this checkout (no install needed).
set -euo pipefail

# Locate the rubygems checkout (two levels up from this script).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

echo "Using rubygems checkout: $REPO"
exec ruby --disable-gems -I"$REPO/lib" -rrubygems -I"$REPO/bundler/lib" \
  "$HERE/prove_resolution.rb"
