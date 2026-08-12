# frozen_string_literal: true

RSpec.describe "bundle install with content-addressable gems", :compact_index, rubygems: ">= 4.1.0.dev" do
  before do
    skip "Gem::ContentAddress not available" if ruby_core?
  end

  let(:current_abi) { "#{Gem.ruby_version.segments[0]}.#{Gem.ruby_version.segments[1]}" }
  let(:mismatched_abi) { "#{Gem.ruby_version.segments[0] + 1}.0" }

  it "installs the content-addressed gem when the Ruby ABI matches" do
    simulate_platform "x86_64-linux" do
      build_repo2 do
        build_gem "mygem", "1.0" do |s|
          s.platform = Gem::Platform.new("x86_64-linux")
          s.write "lib/mygem.rb", "MYGEM = '1.0 not_content_addressed'"
        end
      end

      build_gem "mygem", "1.0", ruby_abi: current_abi, path: gem_repo2("gems") do |s|
        s.platform = Gem::Platform.new("x86_64-linux")
        s.required_ruby_version = "~> #{current_abi}.0"
        s.write "lib/mygem.rb", "MYGEM = '1.0 content_addressed'"
      end

      install_gemfile <<~G, artifice: "compact_index_v2", env: { "BUNDLER_SPEC_GEM_REPO" => gem_repo2.to_s }
        source "https://gem.repo2"

        gem "mygem"
      G

      expect(the_bundle).to include_gems "mygem 1.0 content_addressed"
    end
  end

  it "falls back to the non-content-addressed gem when the content-addressed gem requires a different Ruby ABI" do
    simulate_platform "x86_64-linux" do
      build_repo2 do
        build_gem "mygem", "1.0" do |s|
          s.platform = Gem::Platform.new("x86_64-linux")
          s.write "lib/mygem.rb", "MYGEM = '1.0 not_content_addressed'"
        end
      end

      build_gem "mygem", "1.0", ruby_abi: mismatched_abi, path: gem_repo2("gems") do |s|
        s.platform = Gem::Platform.new("x86_64-linux")
        s.required_ruby_version = "~> #{mismatched_abi}.0"
        s.write "lib/mygem.rb", "MYGEM = '1.0 content_addressed'"
      end

      install_gemfile <<~G, artifice: "compact_index_v2", env: { "BUNDLER_SPEC_GEM_REPO" => gem_repo2.to_s }
        source "https://gem.repo2"

        gem "mygem"
      G

      expect(the_bundle).to include_gems "mygem 1.0 not_content_addressed"
    end
  end

  it "does not treat a content-addressed suffix as content-addressable when platform metadata is missing" do
    simulate_platform "x86_64-linux" do
      build_repo2 do
        build_gem "mygem", "1.0" do |s|
          s.platform = "abcdef12"
          s.write "lib/mygem.rb", "MYGEM = '1.0 hex_platform'"
        end
      end

      install_gemfile <<~G, artifice: "compact_index_v2", env: { "BUNDLER_SPEC_GEM_REPO" => gem_repo2.to_s }, raise_on_error: false
        source "https://gem.repo2"

        gem "mygem"
      G

      expect(err).to include("Could not find gem 'mygem'")
    end
  end

  it "falls back to the non-content-addressed gem when the content-addressed gem is for a different platform" do
    simulate_platform "x86_64-linux" do
      build_repo2 do
        build_gem "mygem", "1.0" do |s|
          s.platform = Gem::Platform.new("x86_64-linux")
          s.write "lib/mygem.rb", "MYGEM = '1.0 not_content_addressed'"
        end
      end

      build_gem "mygem", "1.0", ruby_abi: current_abi, path: gem_repo2("gems") do |s|
        s.platform = Gem::Platform.new("arm64-darwin")
        s.required_ruby_version = "~> #{current_abi}.0"
        s.write "lib/mygem.rb", "MYGEM = '1.0 content_addressed'"
      end

      install_gemfile <<~G, artifice: "compact_index_v2", env: { "BUNDLER_SPEC_GEM_REPO" => gem_repo2.to_s }
        source "https://gem.repo2"

        gem "mygem"
      G

      expect(the_bundle).to include_gems "mygem 1.0 not_content_addressed"
    end
  end

  it "installs the content-addressed gem matching the current platform when multiple platforms are available" do
    simulate_platform "x86_64-linux" do
      build_repo2

      build_gem "mygem", "1.0", ruby_abi: current_abi, path: gem_repo2("gems") do |s|
        s.platform = Gem::Platform.new("x86_64-linux")
        s.required_ruby_version = "~> #{current_abi}.0"
        s.write "lib/mygem.rb", "MYGEM = '1.0 content_addressed_linux'"
      end

      build_gem "mygem", "1.0", ruby_abi: current_abi, path: gem_repo2("gems") do |s|
        s.platform = Gem::Platform.new("arm64-darwin")
        s.required_ruby_version = "~> #{current_abi}.0"
        s.write "lib/mygem.rb", "MYGEM = '1.0 content_addressed_darwin'"
      end

      install_gemfile <<~G, artifice: "compact_index_v2", env: { "BUNDLER_SPEC_GEM_REPO" => gem_repo2.to_s }
        source "https://gem.repo2"

        gem "mygem"
      G

      expect(the_bundle).to include_gems "mygem 1.0 content_addressed_linux"
    end
  end

  it "falls back to the pure-ruby gem when the content-addressed fat gem requires a different Ruby ABI" do
    simulate_platform "x86_64-linux" do
      build_repo2 do
        build_gem "mygem", "1.0" do |s|
          s.write "lib/mygem.rb", "MYGEM = '1.0 pure_ruby'"
        end
      end

      build_gem "mygem", "1.0", ruby_abi: mismatched_abi, path: gem_repo2("gems") do |s|
        s.platform = Gem::Platform.new("x86_64-linux")
        s.required_ruby_version = "~> #{mismatched_abi}.0"
        s.write "lib/mygem.rb", "MYGEM = '1.0 content_addressed'"
      end

      install_gemfile <<~G, artifice: "compact_index_v2", env: { "BUNDLER_SPEC_GEM_REPO" => gem_repo2.to_s }
        source "https://gem.repo2"

        gem "mygem"
      G

      expect(the_bundle).to include_gems "mygem 1.0 pure_ruby"
    end
  end

  it "installs the ABI-compatible content-addressed gem when multiple content-addressed gems are available for the same platform" do
    simulate_platform "x86_64-linux" do
      build_repo2

      build_gem "mygem", "1.0", ruby_abi: current_abi, path: gem_repo2("gems") do |s|
        s.platform = Gem::Platform.new("x86_64-linux")
        s.required_ruby_version = "~> #{current_abi}.0"
        s.write "lib/mygem.rb", "MYGEM = '1.0 content_addressed_matching_abi'"
      end

      build_gem "mygem", "1.0", ruby_abi: mismatched_abi, path: gem_repo2("gems") do |s|
        s.platform = Gem::Platform.new("x86_64-linux")
        s.required_ruby_version = "~> #{mismatched_abi}.0"
        s.write "lib/mygem.rb", "MYGEM = '1.0 content_addressed_mismatched_abi'"
      end

      install_gemfile <<~G, artifice: "compact_index_v2", env: { "BUNDLER_SPEC_GEM_REPO" => gem_repo2.to_s }
        source "https://gem.repo2"

        gem "mygem"
      G

      expect(the_bundle).to include_gems "mygem 1.0 content_addressed_matching_abi"
    end
  end

  it "installs the higher non-content-addressed version over a lower content-addressed version" do
    simulate_platform "x86_64-linux" do
      build_repo2 do
        build_gem "mygem", "2.0" do |s|
          s.platform = Gem::Platform.new("x86_64-linux")
          s.write "lib/mygem.rb", "MYGEM = '2.0 not_content_addressed'"
        end
      end

      build_gem "mygem", "1.0", ruby_abi: current_abi, path: gem_repo2("gems") do |s|
        s.platform = Gem::Platform.new("x86_64-linux")
        s.required_ruby_version = "~> #{current_abi}.0"
        s.write "lib/mygem.rb", "MYGEM = '1.0 content_addressed'"
      end

      install_gemfile <<~G, artifice: "compact_index_v2", env: { "BUNDLER_SPEC_GEM_REPO" => gem_repo2.to_s }
        source "https://gem.repo2"

        gem "mygem"
      G

      expect(the_bundle).to include_gems "mygem 2.0 not_content_addressed"
    end
  end
end
