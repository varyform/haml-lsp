# frozen_string_literal: true

require "json"

module HamlLsp
  # JSON-RPC over the LSP base protocol (Content-Length framed messages).
  class Transport
    class ClosedError < StandardError; end

    def initialize(input, output)
      @input = input
      @output = output
      @input.binmode if @input.respond_to?(:binmode)
      @output.binmode if @output.respond_to?(:binmode)
      @write_lock = Mutex.new
    end

    # Reads one message. Returns nil on EOF.
    def read
      content_length = nil

      loop do
        line = @input.gets
        return nil if line.nil?

        line = line.chomp
        break if line.empty?

        name, value = line.split(":", 2)
        content_length = value.to_i if name&.casecmp?("Content-Length")
      end

      return nil if content_length.nil?

      body = @input.read(content_length)
      return nil if body.nil? || body.bytesize < content_length

      JSON.parse(body.force_encoding(Encoding::UTF_8), symbolize_names: true)
    end

    def write(message)
      body = JSON.generate(message)
      @write_lock.synchronize do
        @output.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
        @output.flush
      end
    rescue IOError, Errno::EPIPE
      raise ClosedError
    end
  end
end
