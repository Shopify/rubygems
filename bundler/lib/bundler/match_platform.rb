# frozen_string_literal: true

module Bundler
  module MatchPlatform
    def installable_on_platform?(target_platform) # :nodoc:
      return true if [Gem::Platform::RUBY, nil, target_platform].include?(platform)
      return true if Gem::Platform.new(platform) === target_platform

      false
    end

    def self.select_best_platform_match(specs, platform, force_ruby: false, prefer_locked: false)
      matching = select_all_platform_match(specs, platform, force_ruby: force_ruby, prefer_locked: prefer_locked)

      Gem::Platform.sort_and_filter_best_platform_match(matching, platform)
    end

    def self.select_best_local_platform_match(specs, force_ruby: false)
      local = Bundler.local_platform
      matching = select_all_platform_match(specs, local, force_ruby: force_ruby).filter_map(&:materialized_for_installation)

      Gem::Platform.sort_best_platform_match(matching, local)
    end

    def self.content_addressable?(spec)
      spec.respond_to?(:content_addressable?) && spec.content_addressable?
    end

    # A skinny binary targets exactly one Ruby ABI (e.g. `~> 3.2.0`). Those
    # ranges are disjoint, so at most one skinny variant per (gem, version,
    # platform) is compatible with the running Ruby. Only a Ruby-compatible
    # skinny may displace the fat/ruby fallback.
    def self.usable_skinny?(spec)
      return false unless content_addressable?(spec)

      req = spec.required_ruby_version
      req.nil? || req.none? || req.satisfied_by?(Gem.ruby_version)
    end

    def self.select_all_platform_match(specs, platform, force_ruby: false, prefer_locked: false)
      matching = specs.select {|spec| spec.installable_on_platform?(force_ruby ? Gem::Platform::RUBY : platform) }

      # Only choose the skinny (content-addressable) binary: when a skinny variant
      # compatible with the running Ruby exists, prefer it exclusively. If no
      # skinny matches this Ruby, keep the fat/ruby variants as a fallback so we
      # never strand a usable binary. Because per-minor `~>` ranges are disjoint,
      # at most one skinny qualifies — no skinny-vs-skinny tie-break is needed.
      unless force_ruby
        skinny = matching.select {|spec| usable_skinny?(spec) }
        matching = skinny if skinny.any?
      end

      specs.each(&:force_ruby_platform!) if force_ruby

      if prefer_locked
        locked_originally = matching.select {|spec| spec.is_a?(::Bundler::LazySpecification) }
        return locked_originally if locked_originally.any?
      end

      matching
    end

    def self.generic_local_platform_is_ruby?
      Bundler.generic_local_platform == Gem::Platform::RUBY
    end
  end
end
