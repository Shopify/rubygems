# frozen_string_literal: true

require_relative "compact_index"

# The vendored compact_index is pinned (in spec/support/rubygems_ext.rb) to a ref
# of rubygems/rubygems.org#lib/compact_index/ that predates content-addressable
# gem support. The pin lives in an external app, so it can't be bumped from here.
# Prepend a module that adds CA support by delegating to +super+ and only
# injecting CA-specific behavior: the version token carries the content address,
# and /info appends the real platform as +platform:=+ metadata for CA gems.
# When Gem::ContentAddress is not available (system RubyGems), the no-op
# stub from rubygems_ext.rb makes match? return false, so CA paths are inert.
#
# TODO: Remove this patch once rubygems/rubygems.org PR #6674 merges and the
# pinned ref is updated to include native CA support.
if defined?(CompactIndex::GemVersionMethods)
  module CAGemVersionMethods
    def number_and_platform
      return "#{number}-#{content_address}" if content_address

      super
    end

    def to_line
      line = super
      line << ",platform:= #{platform}" if content_address
      line
    end
  end
  CompactIndex::GemVersionMethods.prepend(CAGemVersionMethods)

  CompactIndex::GemVersionV2.attr_accessor :content_address
end

class CompactIndexV2API < CompactIndexAPI
  helpers do
    def build_gem_version(spec, deps, checksum)
      created_at = spec.date&.utc&.iso8601
      version = CompactIndex::GemVersionV2.new(spec.version.version, spec.platform.to_s, checksum, nil,
        deps, spec.required_ruby_version.to_s, spec.required_rubygems_version.to_s, created_at)
      version.content_address = spec.content_address
      version
    end

    def content_addressable_specs(gem_repo)
      Dir.glob(File.join(gem_repo, "gems", "*.gem")).filter_map do |file|
        token = File.basename(file, ".gem").rpartition("-").last
        next unless Gem::ContentAddress.match?(token)

        spec = Gem::Package.new(file).spec
        next unless Gem::ContentAddress.applicable?(spec)
        spec.content_address = token
        spec
      end
    end
  end

  def gems(gem_repo = default_gem_repo)
    all_gems = super
    ca_specs = content_addressable_specs(gem_repo)
    ca_specs.group_by(&:name).each do |name, versions|
      gem = all_gems.find {|g| g.name == name }
      new_versions = versions.map do |spec|
        deps = spec.runtime_dependencies.map do |d|
          reqs = d.requirement.requirements.map {|r| r.join(" ") }.join(", ")
          CompactIndex::Dependency.new(d.name, reqs)
        end
        begin
          checksum = Digest(:SHA256).file("#{gem_repo}/gems/#{spec.full_name}.gem").hexdigest
        rescue StandardError
          checksum = nil
        end
        build_gem_version(spec, deps, checksum)
      end
      if gem
        gem.versions.concat(new_versions)
      else
        all_gems << CompactIndex::Gem.new(name, new_versions)
      end
    end
    all_gems
  end
end
