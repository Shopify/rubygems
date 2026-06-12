#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Minimal compact-index gem server for testing content-addressable ("skinny")
# binaries end-to-end, with no external deps (raw TCPServer, threaded).
#
# Serves a directory tree as static files over HTTP/1.1:
#   GET /v2/versions      -> <root>/v2/versions
#   GET /v2/info/<gem>    -> <root>/v2/info/<gem>
#   GET /gems/<file>.gem  -> <root>/gems/<file>.gem
#
# Always returns the full body (200); ignores Range (Bundler's compact-index
# updater handles a full response even when it sent a Range header). Logs every
# request to stderr so you can see exactly what Bundler asks for.
#
# Usage: ruby fake_compact_index.rb <root_dir> <port>

require "socket"

root = File.expand_path(ARGV[0] || ".")
port = Integer(ARGV[1] || "8899")

server = TCPServer.new("127.0.0.1", port)
warn "[fake-index] serving #{root} on http://127.0.0.1:#{port}"

loop do
  conn = server.accept
  Thread.new(conn) do |c|
    begin
      request_line = c.gets
      next unless request_line
      method, path, = request_line.split(" ")
      # drain headers
      while (line = c.gets) && line != "\r\n"; end

      clean = path.split("?", 2).first.to_s
      file = File.join(root, clean)
      warn "[fake-index] #{method} #{clean} -> #{File.exist?(file) ? "200" : "404"}"

      if File.file?(file)
        body = File.binread(file)
        ctype = clean.end_with?(".gem") ? "application/octet-stream" : "text/plain"
        head = +"HTTP/1.1 200 OK\r\n"
        head << "Content-Type: #{ctype}\r\n"
        head << "Content-Length: #{body.bytesize}\r\n"
        head << "Accept-Ranges: none\r\n"
        head << "Connection: close\r\n\r\n"
        c.write(head)
        c.write(body) unless method == "HEAD"
      else
        c.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      end
    rescue => e
      warn "[fake-index] error: #{e.class}: #{e.message}"
    ensure
      c.close rescue nil
    end
  end
end
