# frozen_string_literal: true

require_relative "../command"
require_relative "../local_remote_options"
require_relative "../version_option"
require_relative "../gemcutter_utilities"
require_relative "../package"

class Gem::Commands::PushCommand < Gem::Command
  include Gem::LocalRemoteOptions
  include Gem::VersionOption
  include Gem::GemcutterUtilities

  def description # :nodoc:
    <<-EOF
The push command uploads a gem to the push server (the default is
https://rubygems.org) and adds it to the index.

The gem can be removed from the index and deleted from the server using the yank
command.  For further discussion see the help for the yank command.

The push command will use ~/.gem/credentials to authenticate to a server, but you can use the RubyGems environment variable GEM_HOST_API_KEY to set the api key to authenticate. If the :credential_store: gemrc option (or RUBYGEMS_CREDENTIAL_STORE environment variable) is set, the API key is stored in and read from the credential store it selects instead of ~/.gem/credentials.

The API key to send is resolved in this order: the GEM_HOST_API_KEY environment variable, the --key option, the host's own key in the credential store (when :credential_store: is set), the host's own key in ~/.gem/credentials, then the default RubyGems.org key from either place. The first one found is used.
    EOF
  end

  def arguments # :nodoc:
    "GEM       built gem to push up"
  end

  def usage # :nodoc:
    "#{program_name} GEM"
  end

  def initialize
    super "push", "Push a gem up to the gem server", host: host, attestations: []

    @user_defined_host = false

    add_proxy_option
    add_key_option
    add_otp_option

    add_option("--host HOST",
               "Push to another gemcutter-compatible host",
               "  (e.g. https://rubygems.org)") do |value, options|
      options[:host] = value
      @user_defined_host = true
    end

    add_option("--platform PLATFORM",
               "Push a gem for a specific platform",
               "  (e.g. x86_64-darwin-20)") do |value, options|
      options[:platform] = value
    end

    add_ruby_abi_option("push", "  (e.g. 3.4)")

    add_option("--attestation FILE",
                "Push with sigstore attestations") do |value, options|
      options[:attestations] << value
    end

    @host = nil
  end

  def execute
    gem_name = if gem_name_selectors?
      resolve_gem_name(get_all_gem_names)
    else
      get_one_gem_name
    end

    default_gem_server, push_host = get_hosts_for(gem_name)

    @host = if @user_defined_host
      options[:host]
    elsif default_gem_server
      default_gem_server
    elsif push_host
      push_host
    else
      options[:host]
    end

    sign_in @host, scope: get_push_scope

    send_gem(gem_name)
  end

  def send_gem(name)
    args = [:post, "api/v1/gems"]

    _, push_host = get_hosts_for(name)

    @host ||= push_host

    # Always include @host, even if it's nil
    args += [@host, push_host]

    say "Pushing gem to #{@host || Gem.host}..."

    response = send_push_request(name, args)

    with_response response
  end

  private

  def gem_name_selectors?
    options[:platform] || options[:ruby_abi]
  end

  def resolve_gem_name(names)
    candidates = names.filter_map do |name|
      [name, Gem::Package.new(name).spec]
    rescue Gem::Package::FormatError => e
      alert_warning "Skipping #{name}: #{e.message}"
      nil
    end

    matches = candidates.select do |_, spec|
      platform_matches?(spec) && ruby_matches?(spec)
    end

    raise Gem::CommandLineError, "No gem matched #{gem_name_selector_description}" if matches.empty?
    raise Gem::CommandLineError, multiple_matches_message(matches) if matches.length > 1

    matches.first.first
  end

  def multiple_matches_message(matches)
    message = "Multiple gems matched #{gem_name_selector_description}: #{matches.map(&:first).join(", ")}"
    suggestion = multiple_matches_suggestion(matches)
    message += "\n#{suggestion}" if suggestion
    message
  end

  def multiple_matches_suggestion(matches)
    if options[:platform] && !options[:ruby_abi]
      ruby_abis = matches.filter_map {|_, spec| spec.ruby_abi }.uniq.sort
      suggestions = []
      suggestions << "Specify --ruby-abi with one of: #{ruby_abis.join(", ")}" unless ruby_abis.empty?
      suggestions << "To push a gem without a Ruby ABI, pass the exact filename." if matches.any? {|_, spec| spec.ruby_abi.nil? }
      suggestions.join("\n") unless suggestions.empty?
    elsif options[:ruby_abi] && !options[:platform]
      platforms = matches.map {|_, spec| spec.platform.to_s }.uniq.sort
      "Specify --platform with one of: #{platforms.join(", ")}" unless platforms.empty?
    end
  end

  def gem_name_selector_description
    selectors = []
    selectors << "platform #{options[:platform]}" if options[:platform]
    selectors << "Ruby ABI #{options[:ruby_abi]}" if options[:ruby_abi]
    selectors.join(" and ")
  end

  def platform_matches?(spec)
    !options[:platform] || spec.platform == Gem::Platform.new(options[:platform])
  end

  def ruby_matches?(spec)
    return true unless options[:ruby_abi]

    Gem::ContentAddress.eligible?(spec) && spec.ruby_abi == options[:ruby_abi]
  end

  def send_push_request(name, args)
    # Always honor explicit --attestation option
    # Auto-attestation is only supported on rubygems.org with GitHub Actions (not JRuby)
    if options[:attestations].any? || (RUBY_ENGINE != "jruby" && attestation_supported_host? && ENV["GITHUB_ACTIONS"])
      send_push_request_with_attestation(name, args)
    else
      send_push_request_without_attestation(name, args)
    end
  end

  def send_push_request_without_attestation(name, args)
    scope = get_push_scope
    rubygems_api_request(*args, scope: scope) do |request|
      body = Gem.read_binary name
      request.body = body
      request.add_field "Content-Type",   "application/octet-stream"
      request.add_field "Content-Length", request.body.size
      request.add_field "Authorization", api_key
    end
  end

  def send_push_request_with_attestation(name, args)
    attestations = if options[:attestations].any?
      options[:attestations].map do |attestation|
        Gem.read_binary(attestation)
      end
    else
      bundle_path = attest!(name)
      begin
        [Gem.read_binary(bundle_path)]
      ensure
        File.unlink(bundle_path) if bundle_path && File.exist?(bundle_path)
      end
    end
    bundles = "[" + attestations.join(",") + "]"

    rubygems_api_request(*args, scope: get_push_scope) do |request|
      request.set_form([
        ["gem", Gem.read_binary(name), { filename: name, content_type: "application/octet-stream" }],
        ["attestations", bundles, { content_type: "application/json" }],
      ], "multipart/form-data")
      request.add_field "Authorization", api_key
    end
  rescue StandardError => e
    message = "Failed to push with attestation, retrying without attestation.\n"
    message += if Gem.configuration.really_verbose
      e.full_message
    else
      e.message
    end
    alert_warning message
    send_push_request_without_attestation(name, args)
  end

  def attest!(name)
    require "open3"
    require "shellwords"
    require "tempfile"

    tempfile = Tempfile.new([File.basename(name, ".*"), ".sigstore.json"])
    bundle = tempfile.path
    tempfile.close(false)

    env = defined?(Bundler.unbundled_env) ? Bundler.unbundled_env : ENV.to_h
    # Gem.ruby is quoted if it contains whitespace, so split it into argv
    # elements to keep the quotes out of the spawned command.
    out, st = Open3.capture2e(
      env,
      *Shellwords.split(Gem.ruby), "-S", "gem", "exec", "--conservative",
      "sigstore-cli", "sign", name, "--bundle", bundle,
      unsetenv_others: true
    )
    raise Gem::Exception, "Failed to sign gem:\n\n#{out}" unless st.success?

    bundle
  end

  def get_hosts_for(name)
    gem_metadata = Gem::Package.new(name).spec.metadata

    [
      gem_metadata["default_gem_server"],
      gem_metadata["allowed_push_host"],
    ]
  end

  def get_push_scope
    :push_rubygem
  end

  def attestation_supported_host?
    host = (@host || Gem.host).to_s.chomp("/")
    host == Gem::DEFAULT_HOST
  end
end
