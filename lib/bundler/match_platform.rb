# frozen_string_literal: true

require_relative "content_addressable"

module Bundler
  module MatchPlatform
    include ContentAddressable

    def installable_on_platform?(target_platform) # :nodoc:
      return true if [Gem::Platform::RUBY, nil, target_platform].include?(platform)
      return true if Gem::Platform.new(platform) === target_platform

      false
    end

    def self.select_best_platform_match(specs, platform, force_ruby: false, prefer_locked: false)
      matching = select_all_platform_match(specs, platform, force_ruby: force_ruby, prefer_locked: prefer_locked)

      Gem::Platform.sort_and_filter_best_platform_match(matching, platform)
    end

    # When a content-addressable ("skinny") variant compatible with the running
    # Ruby is present, prefer those exclusively; otherwise drop the skinny rows so
    # the fat/source variant is selected, so a usable binary is never stranded.
    # Per-minor `~>` ABI ranges are disjoint, so at most one skinny qualifies.
    def self.prefer_content_addressable(matching)
      addressable, regular = matching.partition(&:content_addressable?)
      return matching if addressable.empty?

      compatible = addressable.select(&:matches_current_ruby?)
      compatible.any? ? compatible : regular
    end

    def self.select_best_local_platform_match(specs, force_ruby: false, locked_platforms: nil)
      local = Bundler.local_platform
      matching = select_all_platform_match(specs, local, force_ruby: force_ruby).filter_map {|spec| spec.materialized_for_installation(locked_platforms) }

      Gem::Platform.sort_best_platform_match(matching, local)
    end

    def self.select_all_platform_match(specs, platform, force_ruby: false, prefer_locked: false)
      matching = specs.select {|spec| spec.installable_on_platform?(force_ruby ? Gem::Platform::RUBY : platform) }

      specs.each(&:force_ruby_platform!) if force_ruby

      if prefer_locked
        locked_originally = matching.select {|spec| spec.is_a?(::Bundler::LazySpecification) }
        # An existing lock wins to avoid churn; the skinny preference below only
        # applies when not pinned to the lockfile (fresh installs, updates, and
        # the local-platform path, which passes no prefer_locked).
        return locked_originally if locked_originally.any?
      end

      # force_ruby installs the RUBY variant by design, so never prefer skinny then.
      force_ruby ? matching : prefer_content_addressable(matching)
    end

    def self.generic_local_platform_is_ruby?
      Bundler.generic_local_platform == Gem::Platform::RUBY
    end
  end
end
