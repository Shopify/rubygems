# frozen_string_literal: true
require "rubygems/gemcutter_utilities"

class Gem::WebauthnListener
  include Gem::GemcutterUtilities
  attr_reader :port

  def initialize(port = 5678)
    @port = port
  end

  def wait_for_otp_code
    webserver = Thread.new do
      server = TCPServer.new(port)
      begin
        socket = server.accept
        while (request_line = socket.gets)
          method, req_uri, protocol = request_line.split(' ')

          case method.upcase
          when "OPTIONS"
            send_options_response(socket)
          when "GET"
            # code = parse_otp_from_uri(req_uri)
            send_get_response(socket)
          else
            # raise error
          end
          break
        end
      ensure
        server.close
      end
    end
  end

  def parse_otp_from_uri(uri)
  end

  def send_options_response(connection)
    connection.puts "HTTP/1.1 204"
    connection.puts "Access-Control-Allow-Origin: #{host}"
    connection.puts "Access-Control-Allow-Methods: POST"
    connection.puts "Access-Control-Allow-Headers: Content-Type, Authorization, x-csrf-token"
    connection.puts "Connection: close"
    connection.close
  end

  def send_get_response(connection)
    body = "success"

    connection.puts "HTTP/1.1 200"
    connection.puts "Content-Type: text/plain"
    connection.puts "Content-Length: #{body.bytesize}"
    connection.puts "Access-Control-Allow-Origin: #{host}"
    connection.puts "Access-Control-Allow-Methods: POST"
    connection.puts "Access-Control-Allow-Headers: Content-Type, Authorization, x-csrf-token"
    connection.puts "Connection: close"
    connection.puts
    connection.puts body
    connection.close
  end
end
