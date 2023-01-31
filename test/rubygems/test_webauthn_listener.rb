# frozen_string_literal: true
require_relative "helper"
require "rubygems/webauthn_listener"

class WebauthnListenerTest < Gem::TestCase
  def setup
    @server = Gem::WebauthnListener.new
    @server.start
  end

  def test_foo
    puts "dsjkhsdkjf"
    # open fake browser/server
    # send request to the localhost server
    # @socket = TCPSocket.new("localhost", @server.port)
    # @socket.puts "Fred"

    # Gem::FakeBrowser.options URI("http://localhost:5678?code=xyz")

    res = Gem::FakeBrowser.get URI("http://localhost:5678?code=xyz")
    puts res.body

    # uri = URI("http://localhost:5678?code=xyz")
    # res = Net::HTTP.get(uri)
    assert true
  end

  def teardown
    @server.stop
  end
end
