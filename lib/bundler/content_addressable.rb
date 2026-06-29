# frozen_string_literal: true

module Bundler
  # Default content-addressing behavior for specs that are not content-addressable
  # ("skinny") gems. Bundler::EndpointSpecification overrides these.
  #
  # Mixed into every spec type that flows through resolution and selection: into
  # Bundler's own spec classes via MatchPlatform, and directly into
  # Gem::BasicSpecification in rubygems_ext (since Gem specs keep their native
  # `installable_on_platform?` and so never receive MatchPlatform).
  module ContentAddressable
    # A spec opts in to content addressing by overriding #content_address alone;
    # #content_addressable? follows from it so the two can never drift apart.
    def content_address
      nil
    end

    def content_addressable?
      !content_address.nil?
    end
  end
end
