# frozen_string_literal: true

require "bundler/installer/parallel_installer"
require "bundler/rubygems_gem_installer"
require "rubygems/remote_fetcher"
require "bundler"

RSpec.describe Bundler::ParallelInstaller do
  describe "connect to make jobserver" do
    before do
      unless Gem::Installer.private_method_defined?(:build_jobs)
        skip "This example is runnable when RubyGems::Installer implements `build_jobs`"
      end

      require "support/artifice/compact_index"

      @previous_client = Gem::Request::ConnectionPools.client
      Gem::Request::ConnectionPools.client = Gem::Net::HTTP
      Gem::RemoteFetcher.fetcher.close_all

      build_repo2 do
        build_gem "one", &:add_c_extension
        build_gem "two", &:add_c_extension
      end

      gemfile <<~G
        source "https://gem.repo2"

        gem "one"
        gem "two"
      G
      lockfile <<~L
        GEM
          remote: https://gem.repo2/
          specs:
            one (1.0)
            two (1.0)

        DEPENDENCIES
          one
          two
      L

      @old_ui = Bundler.ui
      Bundler.ui = Bundler::UI::Silent.new
    end

    after do
      Bundler.ui = @old_ui
      Gem::Request::ConnectionPools.client = @previous_client
      Artifice.deactivate
    end

    let(:definition) do
      allow(Bundler).to receive(:root) { bundled_app }

      definition = Bundler::Definition.build(bundled_app.join("Gemfile"), bundled_app.join("Gemfile.lock"), false)
      definition.tap(&:setup_domain!)
    end
    let(:installer) { Bundler::Installer.new(bundled_app, definition) }
    let(:gem_one) { definition.specs.find {|spec| spec.name == "one" } }
    let(:gem_two) { definition.specs.find {|spec| spec.name == "two" } }

    it "takes all available slots" do
      redefine_build_jobs do
        Bundler::ParallelInstaller.call(installer, definition.specs, 5, false, true)
      end

      # Take 3 slots out of the 5 available.
      expect(File.read(File.join(gem_one.extension_dir, "gem_make.out"))).to include("make -j3")
      # Take the remaining 2 slots.
      expect(File.read(File.join(gem_two.extension_dir, "gem_make.out"))).to include("make -j2")
    end

    it "fallback to non parallel when no slots are available" do
      redefine_build_jobs do
        Bundler::ParallelInstaller.call(installer, definition.specs, 3, false, true)
      end

      # Take 3 slots out of the 3 available.
      expect(File.read(File.join(gem_one.extension_dir, "gem_make.out"))).to include("make -j3")
      # Fallback to one slot (non parallel).
      expect(File.read(File.join(gem_two.extension_dir, "gem_make.out"))).to_not include("make -j")
    end

    it "uses one jobs when installing serially" do
      Bundler.settings.temporary(jobs: 1) do
        Bundler::ParallelInstaller.call(installer, definition.specs, 1, false, true)
      end

      expect(File.read(File.join(gem_one.extension_dir, "gem_make.out"))).to_not include("make -j")
      expect(File.read(File.join(gem_two.extension_dir, "gem_make.out"))).to_not include("make -j")
    end

    it "release the job slots" do
      build_repo2 do
        build_gem "one", &:add_c_extension
        build_gem "two" do |spec|
          spec.add_c_extension
          spec.add_dependency(:one) # ParallelInstaller will wait for `one` to be fully installed.
        end
      end

      Bundler::ParallelInstaller.call(installer, definition.specs, 3, false, true)

      # Take 3 slots out of the 3 available.
      expect(File.read(File.join(gem_one.extension_dir, "gem_make.out"))).to include("make -j3")
      # Take 3 slots that were released.
      expect(File.read(File.join(gem_two.extension_dir, "gem_make.out"))).to include("make -j3")
    end

    def redefine_build_jobs
      old_method = Bundler::RubyGemsGemInstaller.instance_method(:build_jobs)
      Bundler::RubyGemsGemInstaller.remove_method(:build_jobs)

      gem_one_waiting = true
      gem_two_waiting = true

      Bundler::RubyGemsGemInstaller.define_method(:build_jobs) do
        if spec.name == "one"
          value = old_method.bind(self).call
          gem_one_waiting = false
          sleep(0.1) while gem_two_waiting
        elsif spec.name == "two"
          sleep(0.1) while gem_one_waiting
          value = old_method.bind(self).call
          gem_two_waiting = false
        end

        value
      end

      yield
    ensure
      Bundler::RubyGemsGemInstaller.remove_method(:build_jobs)
      Bundler::RubyGemsGemInstaller.define_method(:build_jobs, old_method)
    end
  end
end
