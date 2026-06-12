# frozen_string_literal: true

module Bundler
  # Detects the versions of system components (libc, C++ stdlib, OS, ...) the
  # *running host* provides, to honor the `<name>:<requirement>` system-requirement
  # tokens carried in the content-addressable compact index.
  #
  # A precompiled binary whose declared floor exceeds what the host provides is
  # skipped during resolution, so Bundler falls back to the source ("ruby"
  # platform) gem and compiles locally instead of installing a binary that would
  # fail to load at runtime.
  #
  # A new requirement is supported by registering a host detector in DETECTORS;
  # the parsing, matching, and source-fallback paths are name-agnostic.
  module SystemRequirements
    # name => callable returning the host's Gem::Version for that component,
    # or nil when it isn't applicable/detectable (e.g. a "musl" floor on a glibc
    # host). Add "musl", "libstdcxx", "darwin", ... here.
    DETECTORS = {
      "glibc" => -> { Glibc.version },
    }.freeze

    # Test seam: BUNDLE_SIMULATE_SYSTEM_REQUIREMENTS="glibc=2.31,musl=1.2"
    OVERRIDE_ENV = "BUNDLE_SIMULATE_SYSTEM_REQUIREMENTS"

    class << self
      # Requirement names this client understands (drives index parsing too).
      def known
        DETECTORS.keys
      end

      # Host version for a requirement name, or nil if N/A / undetectable.
      def host_version(name)
        return overrides[name] if overrides.key?(name)

        (@memo ||= {}).fetch(name) do
          detector = DETECTORS[name]
          @memo[name] = detector && detector.call
        end
      end

      # Does the host satisfy +requirement+ (a Gem::Requirement) for +name+?
      def satisfied?(name, requirement)
        return true if requirement.nil? || requirement.none?

        host = host_version(name)
        return false if host.nil? # floored component the host can't provide/identify

        requirement.satisfied_by?(host)
      end

      # Test seam: simulate a host version for +name+ (nil = "not present").
      def override(name, version)
        overrides[name.to_s] = version.nil? ? nil : Gem::Version.new(version.to_s)
      end

      def reset!
        @overrides = nil
        @memo = nil
      end

      private

      def overrides
        @overrides ||= ENV[OVERRIDE_ENV].to_s.split(",").each_with_object({}) do |pair, acc|
          name, version = pair.split("=", 2)
          next if name.nil? || name.strip.empty?
          acc[name.strip] = version && !version.strip.empty? ? Gem::Version.new(version.strip) : nil
        end
      end
    end

    # glibc: the version the running Ruby process is linked against.
    module Glibc
      class << self
        def version
          via_fiddle || via_getconf || via_ldd
        end

        private

        def via_fiddle
          require "fiddle"
          handle = Fiddle.dlopen(nil)
          func = Fiddle::Function.new(handle["gnu_get_libc_version"], [], Fiddle::TYPE_VOIDP)
          version_or_nil(func.call.to_s)
        rescue StandardError, LoadError
          nil
        end

        def via_getconf
          out = `getconf GNU_LIBC_VERSION 2>/dev/null`.to_s # => "glibc 2.31"
          m = out.match(/glibc\s+(\d+(?:\.\d+)+)/)
          m && version_or_nil(m[1])
        rescue StandardError
          nil
        end

        def via_ldd
          out = `ldd --version 2>&1`.to_s
          return nil if out.match?(/musl/i)

          m = out.match(/(\d+\.\d+(?:\.\d+)?)/)
          m && version_or_nil(m[1])
        rescue StandardError
          nil
        end

        def version_or_nil(str)
          Gem::Version.new(str)
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
