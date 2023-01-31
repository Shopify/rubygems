class Gem::WebauthnListener
  attr_reader :port

  def initialize(port = 5678)
    @port = port
  end


  def start
    webserver = Thread.new do
      begin
        @server = TCPServer.new(port)
        body = "YOYOYOYO"
        connection = @server.accept
        while (input = connection.gets)
          puts input
          # GET /?code=xyz HTTP/1.1
          # Accept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3
          # Accept: */*
          # User-Agent: Ruby
          # Host: localhost:5678

          connection.puts "HTTP/1.1 200"
          connection.puts "Content-Type: text/plain"
          connection.puts "Content-Length: #{body.bytesize}" if body
          connection.puts "Connection: close\r\n"
          connection.puts
          connection.print body
          connection.close

          break
        end
      ensure
        stop
      end
    end

    # 1.times do
    # #loop do
    #   webserver = Thread.start(@server.accept) do |connection|
    #     begin
    #       # byebug
    #       body = "YOYOYOYO"
    #       # while (input = connection.gets)
    #       #   # byebug
    #       # end
    #       connection.puts "HTTP/1.1 200"
    #       connection.puts "Content-Type: text/plain"
    #       connection.puts "Content-Length: #{body.bytesize}" if body
    #       connection.puts "Connection: close\r\n"
    #       connection.puts
    #       connection.print body
    #       connection.close
    #     ensure
    #       stop
    #     end
    #   end
    #   webserver.abort_on_exception = true
    # end

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
