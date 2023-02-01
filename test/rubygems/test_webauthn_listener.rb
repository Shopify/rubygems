# frozen_string_literal: true
require_relative "helper"
require "rubygems/webauthn_listener"

class WebauthnListenerTest < Gem::TestCase
  def setup
    @listener = Gem::WebauthnListener.new
    @listener.wait_for_otp_code
  end

  def test_wait_for_otp_code_options_request
    response = Gem::FakeBrowser.options URI("http://localhost:5678?code=xyz")

    assert response.is_a? Net::HTTPNoContent
    assert_nil response["Content-Type"]
    assert_nil response["Content-Length"]
    assert_equal Gem.host, response["access-control-allow-origin"]
    assert_equal "POST", response["access-control-allow-methods"]
    assert_equal "Content-Type, Authorization, x-csrf-token", response["access-control-allow-headers"]
    assert_equal "close", response["Connection"]

    #assert port is closed
  end

  def test_wait_for_otp_code_get_request_response
    response = Gem::FakeBrowser.get URI("http://localhost:5678?code=xyz")

    assert response.is_a? Net::HTTPOK
    assert_equal "text/plain", response["Content-Type"]
    assert_equal "7", response["Content-Length"]
    assert_equal Gem.host, response["access-control-allow-origin"]
    assert_equal "POST", response["access-control-allow-methods"]
    assert_equal "Content-Type, Authorization, x-csrf-token", response["access-control-allow-headers"]
    assert_equal "close", response["Connection"]
    assert_equal "success", response.body
  end

  def test_wait_for_otp_code_no_otp_param
  end

  # def test_get_request_no_code
  # end

  # def test_invalid_req_method
  # end

  def teardown
    # TODO: remove plz
  end
end
