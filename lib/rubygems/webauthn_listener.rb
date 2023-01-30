class Gem::WebauthnListener
  attr_reader :port

  def initialize(port = 5678)
    @port = port
  end


  def start
    @server = TCPServer.new(port)
    1.times do
    #loop do
      webserver = Thread.start(@server.accept) do |connection|
        begin
          # byebug
          body = "YOYOYOYO"
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
      webserver.abort_on_exception = true
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
