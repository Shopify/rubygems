# frozen_string_literal: true

require "set"

module Bundler
  # The CompactIndexClient is responsible for fetching and parsing the compact index.
  #
  # The compact index is a set of caching optimized files that are used to fetch gem information.
  # The files are:
  # - names: a list of all gem names
  # - versions: a list of all gem versions
  # - info/[gem]: a list of all versions of a gem
  #
  # The client is instantiated with:
  # - `directory`: the root directory where the cache files are stored.
  # - `fetcher`: (optional) an object that responds to #call(uri_path, headers) and returns an http response.
  # If the `fetcher` is not provided, the client will only read cached files from disk.
  #
  # The client is organized into:
  # - `Updater`: updates the cached files on disk using the fetcher.
  # - `Cache`: calls the updater, caches files, read and return them from disk
  # - `Parser`: parses the compact index file data
  # - `CacheFile`: a concurrency safe file reader/writer that verifies checksums
  #
  # The client is intended to optimize memory usage and performance.
  # It is called 100s or 1000s of times, parsing files with hundreds of thousands of lines.
  # It may be called concurrently without global interpreter lock in some Rubies.
  # As a result, some methods may look more complex than necessary to save memory or time.
  class CompactIndexClient
    SUPPORTED_DIGESTS = { "sha-256" => :SHA256 }.freeze
    DEBUG_MUTEX = Thread::Mutex.new

    # API versions this client understands, newest first. v2 adds the
    # content-addressable ("skinny") binary namespace under `/v2/`.
    SUPPORTED_API_VERSIONS = [2, 1].freeze
    API_VERSION_MARKER = "api_version"


    # info returns an Array of INFO Arrays. Each INFO Array has the following indices:
    INFO_NAME = 0
    INFO_VERSION = 1
    INFO_PLATFORM = 2
    INFO_DEPS = 3
    INFO_REQS = 4

    def self.debug
      return unless ENV["DEBUG_COMPACT_INDEX"]
      DEBUG_MUTEX.synchronize { warn("[#{self}] #{yield}") }
    end

    class Error < StandardError; end

    require_relative "compact_index_client/cache"
    require_relative "compact_index_client/cache_file"
    require_relative "compact_index_client/parser"
    require_relative "compact_index_client/updater"

    def initialize(directory, fetcher = nil, api_version: 1)
      @directory = Pathname.new(directory).expand_path
      @fetcher = fetcher
      use_api_version(api_version)
    end

    attr_reader :api_version

    # Determine the newest compact index API version this source actually
    # serves. Newer clients prefer v2 (`/v2/versions`, `/v2/info`); sources that
    # only speak v1 answer the probe with a 404, so we transparently downgrade.
    #
    # We re-probe on every resolve rather than trusting a cached decision
    # forever, so a source that later adds v2 support is picked up. This is
    # consistent with how `versions`/`info` are revalidated every run: the
    # probe's `versions` fetch is an ETag-conditional request, so for the
    # version a source actually serves it costs a cheap 304 when nothing
    # changed. The persisted marker is kept only as an offline fallback (see
    # #probe_api_version!).
    #
    # Only meaningful with a fetcher; read-only clients stay on the version
    # they were constructed with.
    def negotiate_api_version!
      return @api_version unless @fetcher

      probe_api_version!(fallback: persisted_api_version)
    end

    def names
      Bundler::CompactIndexClient.debug { "names" }
      @parser.names
    end

    def versions
      Bundler::CompactIndexClient.debug { "versions" }
      @parser.versions
    end

    def dependencies(names)
      Bundler::CompactIndexClient.debug { "dependencies(#{names})" }
      names.map {|name| info(name) }
    end

    def info(name)
      Bundler::CompactIndexClient.debug { "info(#{name})" }
      @parser.info(name)
    end

    def latest_version(name)
      Bundler::CompactIndexClient.debug { "latest_version(#{name})" }
      @parser.info(name).map {|d| Gem::Version.new(d[INFO_VERSION]) }.max
    end

    def available?
      Bundler::CompactIndexClient.debug { "available?" }
      @parser.available?
    end

    def reset!
      Bundler::CompactIndexClient.debug { "reset!" }
      @cache.reset!
    end

    private

    # Probe the source over the wire, newest version first, and persist the
    # result. The `versions` call uses ETag-conditional requests, so probing the
    # version a source serves is cheap on a warm cache (304 Not Modified).
    #
    # If a usable `fallback` version is supplied and the probe fails for any
    # reason other than a clean downgrade (e.g. the network is unreachable),
    # keep using the fallback rather than failing the whole resolve -- this is
    # what lets `bundle install` work offline against a warm cache.
    def probe_api_version!(fallback: nil)
      SUPPORTED_API_VERSIONS.each do |version|
        use_api_version(version)
        begin
          versions # probe: fetches /vN/versions (or /versions for v1)
          persist_api_version(version)
          return @api_version
        rescue Bundler::Fetcher::FallbackError
          # This source doesn't serve this API version (404). Try the next
          # lower one; v1 is unprefixed and always exists for a compact index.
          next unless version == SUPPORTED_API_VERSIONS.last
          raise
        end
      end

      @api_version
    rescue StandardError
      raise unless fallback
      use_api_version(fallback)
      @api_version
    end

    def use_api_version(version)
      version = 1 unless SUPPORTED_API_VERSIONS.include?(version)
      @api_version = version
      @cache = Cache.new(@directory, @fetcher, api_version: version)
      @parser = Parser.new(@cache)
    end

    def api_version_marker_path
      @directory.join(API_VERSION_MARKER)
    end

    def persisted_api_version
      path = api_version_marker_path
      return unless path.file?
      version = path.read.to_i
      SUPPORTED_API_VERSIONS.include?(version) ? version : nil
    rescue StandardError
      nil
    end

    def persist_api_version(version)
      api_version_marker_path.write(version.to_s)
    rescue StandardError
      nil
    end
  end
end
