# frozen_string_literal: true

# Proof: content-addressable ("skinny") gems encoded in the **v1** compact index
# are (a) chosen by a new client over the fat and source variants, and (b)
# ignored by old clients via the `rubygems:` requirement gate.
#
# This deliberately uses the *real* client code paths -- the host RubyGems
# compact-index line parser (Gem::Resolver::APISet::GemParser), the real
# Bundler::EndpointSpecification (built exactly like Bundler::Fetcher#specs
# does), and the real Bundler::MatchPlatform platform selection -- so the
# demo proves the production behaviour, not a reimplementation.
#
# Run with the patched RubyGems + Bundler from this checkout:
#
#   ruby --disable-gems -Ilib -rrubygems -Ibundler/lib \
#     dev/content-addressable-v1-demo/prove_resolution.rb
#
# (test_resolution.sh wires that up for you.)

require "bundler"
require "bundler/endpoint_specification"
require "bundler/match_platform"
require "rubygems/resolver"

# The RubyGems version at which content-addressable support ships. New clients
# satisfy this; old clients do not and therefore drop the skinny rows.
CA_SUPPORTED_FROM = "4.1.0.dev"

LOCAL = Gem::Platform.local                       # e.g. arm64-darwin-24 / x86_64-linux
RUBY_MINOR = RUBY_VERSION.split(".").first(2).join(".") # e.g. "4.0"
SHA10 = "ef716ba7a6"                              # sha256(.gem)[0,10]

# A single gem `hola 1.0.0` published in three shapes, exactly as it would
# appear in the v1 `/info/hola` file. Order mirrors the Slack proposal: the
# content-addressable rows come last and carry `rubygems:>=` + `platform:`.
INFO = <<~INFO
  ---
  1.0.0 |checksum:#{"a" * 64},ruby:>= 3.1,rubygems:>= 3.3.22
  1.0.0-#{LOCAL} |checksum:#{"b" * 64},ruby:>= 3.1
  1.0.0-#{SHA10} |checksum:#{"c" * 64},ruby:~> #{RUBY_MINOR}.0,rubygems:>= #{CA_SUPPORTED_FROM},platform:= #{LOCAL}
INFO

# Minimal spec fetcher stand-in: EndpointSpecification only needs #uri (for
# checksum attribution). #fetch_spec is never reached in this offline demo.
FakeFetcher = Struct.new(:uri) do
  def fetch_spec(*) = raise("network access not expected in this demo")
end
FETCHER = FakeFetcher.new("https://example.test")

# Build EndpointSpecifications from the info file using the real parser, the
# same way Bundler::Fetcher#specs does (name, version, platform, deps, metadata).
def build_specs(info)
  parser = Gem::Resolver::APISet::GemParser.new
  lines = info.split("\n")
  body = lines[(lines.index("---") + 1)..]
  body.map do |line|
    version, platform, deps, reqs = parser.parse(line)
    Bundler::EndpointSpecification.new("hola", version, platform, FETCHER, deps, reqs)
  end
end

def describe(spec)
  kind =
    if spec.content_addressable? then "SKINNY (content-addressable)"
    elsif spec.platform == Gem::Platform::RUBY then "source  (ruby platform)"
    else "fat     (precompiled platform)"
    end
  "#{spec.full_name.ljust(28)} -> #{kind}"
end

specs = build_specs(INFO)

puts "Running RubyGems #{Gem::VERSION}, Ruby #{RUBY_VERSION}, platform #{LOCAL}"
puts
puts "Parsed v1 /info/hola into #{specs.size} candidate specs:"
specs.each {|s| puts "  #{describe(s)}" }
puts

# ---------------------------------------------------------------------------
# Part 1: a NEW client (this RubyGems) picks the skinny variant.
# ---------------------------------------------------------------------------
chosen = Bundler::MatchPlatform.select_best_platform_match(specs, LOCAL)
raise "expected exactly one winner, got #{chosen.size}" unless chosen.size == 1
winner = chosen.first

puts "[new client] select_best_platform_match(#{LOCAL}) chose:"
puts "  #{describe(winner)}"
puts "  download name: #{winner.full_name}.gem  (reconstructed from version + sha)"
puts

unless winner.content_addressable?
  abort "FAIL: expected the skinny (content-addressable) gem to be chosen"
end

# ---------------------------------------------------------------------------
# Part 2: an OLD client drops the skinny rows via the `rubygems:` gate.
# `matches_current_rubygems?` is exactly the lever the resolver uses to
# exclude metadata-incompatible candidates. We simulate an old client by
# checking the gate against a pre-CA RubyGems version.
# ---------------------------------------------------------------------------
old_rubygems = Gem::Version.new("3.5.0")
skinny = specs.find(&:content_addressable?)
gate = skinny.required_rubygems_version
old_client_keeps_skinny = gate.satisfied_by?(old_rubygems)
new_client_keeps_skinny = skinny.matches_current_rubygems?

puts "[gate] skinny row declares rubygems:#{gate}"
puts "  old client (RubyGems #{old_rubygems}): keeps skinny? #{old_client_keeps_skinny}  -> ignores it"
puts "  new client (RubyGems #{Gem::VERSION}): keeps skinny? #{new_client_keeps_skinny}  -> processes it"
puts

if old_client_keeps_skinny
  abort "FAIL: an old client should NOT satisfy the rubygems gate"
end
unless new_client_keeps_skinny
  abort "FAIL: this (new) client should satisfy the rubygems gate"
end

# What an OLD client would actually resolve: drop gated-out rows first, then
# run the same platform selection. It must fall back to the fat binary.
old_visible = specs.reject {|s| !s.required_rubygems_version.satisfied_by?(old_rubygems) }
old_winner = Bundler::MatchPlatform.select_best_platform_match(old_visible, LOCAL).first
puts "[old client] after dropping gated rows, select_best_platform_match chose:"
puts "  #{describe(old_winner)}"
if old_winner.content_addressable?
  abort "FAIL: old client should fall back to the fat binary, not the skinny one"
end
puts

puts "ALL GOOD: new clients choose the skinny gem; old clients fall back to fat."
