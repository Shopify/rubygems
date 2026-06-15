# frozen_string_literal: true

require "rubygems/resolver/api_set/gem_parser"

module Bundler
  class CompactIndexClient
    class Cache
      attr_reader :directory

      def initialize(directory, fetcher = nil, api_version: 1)
        @directory = Pathname.new(directory).expand_path
        @updater = Updater.new(fetcher) if fetcher
        @mutex = Thread::Mutex.new
        @endpoints = Set.new
        @api_version = api_version

        # `names` is shared across API versions. `versions` and `info` differ
        # between v1 and v2 (different info checksums and content-addressable
        # version tokens), so their cache files live under a per-version
        # subdirectory to avoid collisions with a previously-cached v1.
        @versioned_directory = api_version >= 2 ? mkdir(@directory.join("v#{api_version}")) : @directory

        @info_root = mkdir(@versioned_directory.join("info"))
        @special_characters_info_root = mkdir(@versioned_directory.join("info-special-characters"))
        @info_etag_root = mkdir(@versioned_directory.join("info-etags"))
      end

      def names
        fetch("names", names_path, names_etag_path)
      end

      def versions
        fetch("#{remote_prefix}versions", versions_path, versions_etag_path)
      end

      def info(name, remote_checksum = nil)
        path = info_path(name)

        if remote_checksum && remote_checksum != SharedHelpers.checksum_for_file(path, :MD5)
          fetch("#{remote_prefix}info/#{name}", path, info_etag_path(name))
        else
          Bundler::CompactIndexClient.debug { "update skipped info/#{name} (#{remote_checksum ? "versions index checksum is nil" : "versions index checksum matches local"})" }
          read(path)
        end
      end

      def reset!
        @mutex.synchronize { @endpoints.clear }
      end

      private

      # v1 paths are unprefixed for backwards compatibility; v2+ are served under
      # a `v<N>/` path namespace so old clients never see content-addressable
      # entries.
      def remote_prefix
        @api_version >= 2 ? "v#{@api_version}/" : ""
      end

      def names_path = directory.join("names")
      def names_etag_path = directory.join("names.etag")
      def versions_path = @versioned_directory.join("versions")
      def versions_etag_path = @versioned_directory.join("versions.etag")

      def info_path(name)
        name = name.to_s
        # TODO: converge this into the info_root by hashing all filenames like info_etag_path
        if /[^a-z0-9_-]/.match?(name)
          name += "-#{SharedHelpers.digest(:MD5).hexdigest(name).downcase}"
          @special_characters_info_root.join(name)
        else
          @info_root.join(name)
        end
      end

      def info_etag_path(name)
        name = name.to_s
        @info_etag_root.join("#{name}-#{SharedHelpers.digest(:MD5).hexdigest(name).downcase}")
      end

      def mkdir(dir)
        SharedHelpers.filesystem_access(dir) do
          FileUtils.mkdir_p(dir)
        end
        dir
      end

      def fetch(remote_path, path, etag_path)
        if already_fetched?(remote_path)
          Bundler::CompactIndexClient.debug { "already fetched #{remote_path}" }
        else
          Bundler::CompactIndexClient.debug { "fetching #{remote_path}" }
          @updater&.update(remote_path, path, etag_path)
        end

        read(path)
      end

      def already_fetched?(remote_path)
        @mutex.synchronize { !@endpoints.add?(remote_path) }
      end

      def read(path)
        return unless path.file?
        SharedHelpers.filesystem_access(path, :read, &:read)
      end
    end
  end
end
