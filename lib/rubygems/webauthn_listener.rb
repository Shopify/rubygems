class Gem::WebauthnListener
  attr_reader :port

  def initialize(port = 5678)
    @port = port
  end

  def start
    webserver = Thread.new do
      begin
        @server = TCPServer.new(port)
        # byebug
        body = "YOYOYOYO"
        connection = @server.accept
        # while (input = connection.gets)
        #   # byebug
        # end
        connection.puts "HTTP/1.1 200"
        connection.puts "Content-Type: text/plain"
        connection.puts "Content-Length: #{body.bytesize}" if body
        connection.puts "Connection: close\r\n"
        connection.puts
        connection.print body
        connection.close
      ensure
        stop
      end
    end

    # webserver.join
    # socket waits for a request
    # once you get a request
    # it'll send something back
    # close the socket
  end

  def stop
    @server.close
  end
end
