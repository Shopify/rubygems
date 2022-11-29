# frozen_string_literal: true
require_relative "remote_fetcher"
require_relative "text"

##
# Utility methods for using the RubyGems API.

module Gem::GemcutterUtilities

  ERROR_CODE = 1
  API_SCOPES = %i[index_rubygems push_rubygem yank_rubygem add_owner remove_owner access_webhooks show_dashboard].freeze

  include Gem::Text

  attr_writer :host
  attr_writer :scope

  ##
  # Add the --key option

  def add_key_option
    add_option("-k", "--key KEYNAME", Symbol,
               "Use the given API key",
               "from #{Gem.configuration.credentials_path}") do |value,options|
      options[:key] = value
    end
  end

  ##
  # Add the --otp option

  def add_otp_option
    add_option("--otp CODE",
               "Digit code for multifactor authentication",
               "You can also use the environment variable GEM_HOST_OTP_CODE") do |value, options|
      options[:otp] = value
    end
  end

  ##
  # The API key from the command options or from the user's configuration.

  def api_key
    if ENV["GEM_HOST_API_KEY"]
      ENV["GEM_HOST_API_KEY"]
    elsif options[:key]
      verify_api_key options[:key]
    elsif Gem.configuration.api_keys.key?(host)
      Gem.configuration.api_keys[host]
    else
      Gem.configuration.rubygems_api_key
    end
  end

  ##
  # The OTP code from the command options or from the user's configuration.

  def otp
    options[:otp] || ENV["GEM_HOST_OTP_CODE"]
  end

  ##
  # The host to connect to either from the RUBYGEMS_HOST environment variable
  # or from the user's configuration

  def host
    configured_host = Gem.host unless
      Gem.configuration.disable_default_gem_server

    @host ||=
      begin
        env_rubygems_host = ENV["RUBYGEMS_HOST"]
        env_rubygems_host = nil if
          env_rubygems_host && env_rubygems_host.empty?

        env_rubygems_host || configured_host
      end
  end

  ##
  # Creates an RubyGems API to +host+ and +path+ with the given HTTP +method+.
  #
  # If +allowed_push_host+ metadata is present, then it will only allow that host.

  def rubygems_api_request(method, path, host = nil, allowed_push_host = nil, scope: nil, email: nil, password: nil, &block)
    require 'net/http'

    self.host = host if host
    unless self.host
      alert_error "You must specify a gem server"
      terminate_interaction(ERROR_CODE)
    end

    if allowed_push_host
      allowed_host_uri = URI.parse(allowed_push_host)
      host_uri         = URI.parse(self.host)

      unless (host_uri.scheme == allowed_host_uri.scheme) && (host_uri.host == allowed_host_uri.host)
        alert_error "#{self.host.inspect} is not allowed by the gemspec, which only allows #{allowed_push_host.inspect}"
        terminate_interaction(ERROR_CODE)
      end
    end

    uri = URI.parse "#{self.host}/#{path}"
    response = request_with_otp(method, uri, &block)

    if mfa_unauthorized?(response)
      ask_otp(email, password)
      response = request_with_otp(method, uri, &block)
    end

    if api_key_forbidden?(response)
      update_scope(scope)
      request_with_otp(method, uri, &block)
    else
      response
    end
  end

  def mfa_unauthorized?(response)
    response.kind_of?(Net::HTTPUnauthorized) && response.body.start_with?("You have enabled multifactor authentication")
  end

  def update_scope(scope)
    sign_in_host        = self.host
    pretty_host         = pretty_host(sign_in_host)
    update_scope_params = { scope => true }

    say "The existing key doesn't have access of #{scope} on #{pretty_host}. Please sign in to update access."

    email    = ask "   Email: "
    password = ask_for_password "Password: "

    response = rubygems_api_request(:put, "api/v1/api_key",
                                    sign_in_host, scope: scope) do |request|
      request.basic_auth email, password
      request["OTP"] = otp if otp
      request.body = URI.encode_www_form({ :api_key => api_key }.merge(update_scope_params))
    end

    with_response response do |resp|
      say "Added #{scope} scope to the existing API key"
    end
  end

  ##
  # Signs in with the RubyGems API at +sign_in_host+ and sets the rubygems API
  # key.

  def sign_in(sign_in_host = nil, scope: nil)
    sign_in_host ||= self.host
    return if api_key

    pretty_host = pretty_host(sign_in_host)

    say "Enter your #{pretty_host} credentials."
    say "Don't have an account yet? " +
        "Create one at #{sign_in_host}/sign_up"

    email = ask "   Email: "
    password = ask_for_password "Password: "
    say "\n"

    key_name     = get_key_name(scope)
    scope_params = get_scope_params(scope)
    profile      = get_user_profile(email, password)
    mfa_params   = get_mfa_params(profile)
    all_params   = scope_params.merge(mfa_params)
    warning      = profile["warning"]

    say "#{warning}\n" if warning

    response = rubygems_api_request(:post, "api/v1/api_key",
                                    sign_in_host, email: email, password: password, scope: scope) do |request|
      request.basic_auth email, password
      request["OTP"] = otp if otp
      request.body = URI.encode_www_form({ name: key_name }.merge(all_params))
    end

    with_response response do |resp|
      say "Signed in with API key: #{key_name}."
      set_api_key host, resp.body
    end
  end

  ##
  # Retrieves the pre-configured API key +key+ or terminates interaction with
  # an error.

  def verify_api_key(key)
    if Gem.configuration.api_keys.key? key
      Gem.configuration.api_keys[key]
    else
      alert_error "No such API key. Please add it to your configuration (done automatically on initial `gem push`)."
      terminate_interaction(ERROR_CODE)
    end
  end

  ##
  # If +response+ is an HTTP Success (2XX) response, yields the response if a
  # block was given or shows the response body to the user.
  #
  # If the response was not successful, shows an error to the user including
  # the +error_prefix+ and the response body.

  def with_response(response, error_prefix = nil)
    case response
    when Net::HTTPSuccess then
      if block_given?
        yield response
      else
        say clean_text(response.body)
      end
    else
      message = response.body
      message = "#{error_prefix}: #{message}" if error_prefix

      say clean_text(message)
      terminate_interaction(ERROR_CODE)
    end
  end

  ##
  # Returns true when the user has enabled multifactor authentication from
  # +response+ text and no otp provided by options.

  def set_api_key(host, key)
    if default_host?
      Gem.configuration.rubygems_api_key = key
    else
      Gem.configuration.set_api_key host, key
    end
  end

  private

  def request_with_otp(method, uri, &block)
    request_method = Net::HTTP.const_get method.to_s.capitalize

    Gem::RemoteFetcher.fetcher.request(uri, request_method) do |req|
      req["OTP"] = otp if otp
      block.call(req)
    end
  end

  def ask_otp(email, password)
    webauthn_url = webauthn_verification_url(email, password)
    options[:otp] = unless webauthn_url
      say 'You have enabled multi-factor authentication. Please enter OTP code.'
      ask 'Code: '
    else
      wait_for_response(webauthn_url)
    end
  end

  def wait_for_response(webauthn_url)
    require "cgi"
    # server = TCPServer.new 0
    # server_addr = server.addr[1].to_s

    # for the prototype we hardcode this port
    server = TCPServer.new 5678
    server_addr = 5678

    webserv = Thread.new do
      begin
        loop do
          # loop until a non preflight response is sent and code is received
          break if code_received?(server)
        end
      ensure
        server.close
      end
    end

    webserv.abort_on_exception = true

    redirect_uri = "http://localhost:5678"
    uri = URI.parse(webauthn_url)
    uri.query = URI.encode_www_form(URI.decode_www_form(uri.query || '') << ["redirect_uri", redirect_uri])
    say "You have enabled multi-factor authentication. Please visit #{uri} to authenticate via security device."

    webserv.join
    webserv[:code]
  end

  def code_received?(server)
    response = "Webauthn success"
    response_code = "200 OK"

    connection = server.accept
    while (input = connection.gets)
      begin
        http_req = input.split(' ')
        if http_req.length != 3
          raise "invalid HTTP request received on callback"
        end

        if http_req[0] == "OPTIONS" # if request is a preflight request
          send_response(connection, 204)
          return false
        end

        params = URI.parse(http_req[1]).query
        if params.nil? # also should raise if there is a missing code for params
          raise "no params"
        end
        Thread.current[:code] = CGI.parse(params)["code"][0]
      rescue StandardError => e
        response = "Error processing request: #{e.message}"
        response_code = "400 Bad Request"
      end

      send_response(connection, response_code, response)

      if response_code != "200 OK"
        raise response
      end
      break
    end
    true
  end

  def send_response(connection, code, body = nil)
    connection.puts "HTTP/1.1 #{code}"
    connection.puts "Content-Type: text/plain"
    connection.puts "Content-Length: #{body.bytesize}" if body
    connection.print access_control_headers
    connection.puts "Connection: close\r\n"
    connection.puts
    connection.print body if body
    connection.close
  end

  def access_control_headers
    "Access-Control-Allow-Origin:  http://localhost:3000\r\n"+ # localhost needs to be changed
    "Access-Control-Allow-Methods: POST\r\n"+
    "Access-Control-Allow-Headers: Content-Type, Authorization, x-csrf-token\r\n"
  end

  def webauthn_verification_url(email, password)
    response = rubygems_api_request(:post, "api/v1/webauthn") do |request|
      if email
        request.basic_auth email, password
      else
        request.add_field "Authorization",  api_key
      end
    end
    response.is_a?(Net::HTTPSuccess) ? response.body : nil
  end

  def pretty_host(host)
    if default_host?
      "RubyGems.org"
    else
      host
    end
  end

  def get_scope_params(scope)
    scope_params = {}

    if scope
      scope_params = { scope => true }
    else
      say "Please select scopes you want to enable for the API key (y/n)"
      API_SCOPES.each do |scope|
        selected = ask_yes_no("#{scope}", false)
        scope_params[scope] = true if selected
      end
      say "\n"
    end

    scope_params
  end

  def default_host?
    self.host == Gem::DEFAULT_HOST
  end

  def get_user_profile(email, password)
    return {} unless default_host?

    response = rubygems_api_request(:get, "api/v1/profile/me.yaml") do |request|
      request.basic_auth email, password
    end

    with_response response do |resp|
      Gem::SafeYAML.load clean_text(resp.body)
    end
  end

  def get_mfa_params(profile)
    mfa_level = profile["mfa"]
    params = {}
    if mfa_level == "ui_only" || mfa_level == "ui_and_gem_signin"
      selected = ask_yes_no("Would you like to enable MFA for this key? (strongly recommended)")
      params["mfa"] = true if selected
    end
    params
  end

  def get_key_name(scope)
    hostname = Socket.gethostname || "unknown-host"
    user = ENV["USER"] || ENV["USERNAME"] || "unknown-user"
    ts = Time.now.strftime("%Y%m%d%H%M%S")
    default_key_name = "#{hostname}-#{user}-#{ts}"

    key_name = ask "API Key name [#{default_key_name}]: " unless scope
    if key_name.nil? || key_name.empty?
      default_key_name
    else
      key_name
    end
  end

  def api_key_forbidden?(response)
    response.kind_of?(Net::HTTPForbidden) && response.body.start_with?("The API key doesn't have access")
  end
end
