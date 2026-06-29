# frozen_string_literal: true

require "bundler/endpoint_specification"
require "bundler/match_platform"

# Integration of the bundler-side content-addressable pieces with *real*
# EndpointSpecifications (not doubles): compact-index parsing -> content_address
# /full_name -> platform selection. Exercises the shared select_all_platform_match
# path used by both select_best_platform_match and select_best_local_platform_match.
RSpec.describe "content-addressable gem selection" do
  let(:platform) { Gem::Platform.new("x86_64-linux") }

  # The running Ruby's minor series, e.g. "3.4", so the "compatible" skinny
  # variant tracks whatever Ruby runs the suite.
  let(:this_minor) { Gem.ruby_version.segments.first(2).join(".") }
  let(:other_minor) { "#{Gem.ruby_version.segments[0]}.#{Gem.ruby_version.segments[1] + 1}" }

  def endpoint(name, version, suffix, metadata)
    Bundler::EndpointSpecification.new(name, version, suffix, double(:fetcher), [], metadata)
  end

  def skinny(suffix, ruby_minor)
    endpoint("foo", "1.0.0", suffix, [
      ["ruby", ["~> #{ruby_minor}.0"]],
      ["rubygems", [">= 4.1.0.dev"]],
      ["platform", ["= x86_64-linux"]],
    ])
  end

  let(:fat)    { endpoint("foo", "1.0.0", "x86_64-linux", [["ruby", [">= 3.1"]]]) }
  let(:source) { endpoint("foo", "1.0.0", Gem::Platform::RUBY, [["ruby", [">= 3.1"]]]) }
  let(:compatible_skinny)   { skinny("9f3c1a2b", this_minor) }
  let(:incompatible_skinny) { skinny("1bc1234567", other_minor) }

  it "parses each variant's identity from the compact-index metadata" do
    expect(compatible_skinny).to be_content_addressable
    expect(compatible_skinny.full_name).to eq("foo-1.0.0-9f3c1a2b")
    expect(compatible_skinny.platform).to eq(platform)

    expect(fat).not_to be_content_addressable
    expect(fat.full_name).to eq("foo-1.0.0-x86_64-linux")

    expect(source).not_to be_content_addressable
    expect(source.full_name).to eq("foo-1.0.0")
  end

  it "prefers a Ruby-compatible skinny variant over fat and source" do
    selected = Bundler::MatchPlatform.select_best_platform_match(
      [source, fat, incompatible_skinny, compatible_skinny], platform
    )
    expect(selected.map(&:full_name)).to eq(["foo-1.0.0-9f3c1a2b"])
  end

  it "falls back to fat when no skinny matches the running Ruby" do
    selected = Bundler::MatchPlatform.select_best_platform_match(
      [source, fat, incompatible_skinny], platform
    )
    expect(selected.map(&:full_name)).to eq(["foo-1.0.0-x86_64-linux"])
  end

  it "falls back to source when neither skinny nor fat is available" do
    selected = Bundler::MatchPlatform.select_best_platform_match(
      [source, incompatible_skinny], platform
    )
    expect(selected.map(&:full_name)).to eq(["foo-1.0.0"])
  end

  # Gap 2: the preference lives in the shared select_all_platform_match, so the
  # local-platform path (which calls it directly) prefers skinny too.
  it "applies the skinny preference in the shared select_all_platform_match path" do
    selected = Bundler::MatchPlatform.select_all_platform_match(
      [source, fat, incompatible_skinny, compatible_skinny], platform
    )
    expect(selected.map(&:full_name)).to eq(["foo-1.0.0-9f3c1a2b"])
  end
end
