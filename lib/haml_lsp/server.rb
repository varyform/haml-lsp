# frozen_string_literal: true

require "open3"
require "shellwords"

module HamlLsp
  # The haml-lsp language server.
  #
  # It is a proxy in front of a ruby-lsp process:
  #
  #   * `.haml` documents are opened in ruby-lsp as Ruby documents whose text
  #     is the position-preserving shadow produced by RubyExtractor. Edits from
  #     the editor are applied to the real HAML text here and the shadow is
  #     re-sent to ruby-lsp as a whole-document replacement.
  #   * Because positions in the shadow equal positions in the template, every
  #     other request (hover, definition, completion, signature help, ...) and
  #     its response is forwarded verbatim.
  #   * Requests that only make sense for real Ruby files (formatting, code
  #     actions, RuboCop diagnostics, on-type `end` insertion) are answered
  #     here with empty results, and HAML syntax diagnostics are produced by
  #     the real HAML parser.
  class Server
    class ChildExited < StandardError; end

    HAML_LANGUAGE_ID = "haml"
    RUBY_LANGUAGE_ID = "ruby"

    # Requests ruby-lsp would happily answer for the shadow but whose results
    # would be wrong for a HAML file, with the empty response we give instead.
    SWALLOWED_REQUESTS = {
      "textDocument/formatting" => nil,
      "textDocument/rangeFormatting" => nil,
      "textDocument/onTypeFormatting" => nil,
      "textDocument/codeAction" => [],
    }.freeze

    # Requests that only make sense inside embedded Ruby. Outside of it (in
    # markup or plain text) ruby-lsp would either answer with noise or with
    # nothing, so they are answered here without a round trip.
    RUBY_ONLY_REQUESTS = %w[textDocument/hover textDocument/signatureHelp textDocument/definition].freeze

    # Characters that start a HAML construct we offer completions for.
    HAML_TRIGGER_CHARACTERS = %w[% : !].freeze

    INTERNAL_ERROR = -32_603
    MESSAGE_TYPE_ERROR = 1

    def initialize(input: $stdin, output: $stdout, error: $stderr, ruby_lsp_command: nil)
      @client = Transport.new(input, output)
      @log_io = error
      @ruby_lsp_command = ruby_lsp_command
      @documents = {}
      @pending = {}
      @pending_lock = Mutex.new
      @encoding = PositionEncoding.new
      @supports_pull_diagnostics = false
      @server = nil
      @child = nil
      @exiting = false
      @debug = !ENV["HAML_LSP_DEBUG"].to_s.empty?
    end

    # Runs until the client closes the connection or sends `exit`.
    # Returns the process exit status.
    def run
      @main_thread = Thread.current

      while (message = @client.read)
        handle_client_message(message)
        break if @exiting
      end
      0
    rescue ChildExited
      notify_client_error("ruby-lsp exited unexpectedly; haml-lsp is shutting down.")
      1
    rescue Transport::ClosedError
      0
    ensure
      @exiting = true
      shutdown_child
    end

    private

    # ------------------------------------------------------------------
    # Client -> server
    # ------------------------------------------------------------------

    def handle_client_message(message)
      debug("client -> ", message)
      method = message[:method]

      # A response from the client to a request ruby-lsp made (progress, registrations, ...).
      return forward_to_server(message) if method.nil?

      case method
      when "initialize" then handle_initialize(message)
      when "textDocument/didOpen" then did_open(message)
      when "textDocument/didChange" then did_change(message)
      when "textDocument/didClose" then did_close(message)
      when "textDocument/diagnostic" then diagnostic(message)
      when "textDocument/completion" then completion(message)
      when "completionItem/resolve" then completion_item_resolve(message)
      when *RUBY_ONLY_REQUESTS then ruby_only_request(message)
      when "exit"
        @exiting = true
        forward_to_server(message)
      else
        uri = message.dig(:params, :textDocument, :uri)
        if message.key?(:id) && SWALLOWED_REQUESTS.key?(method) && @documents.key?(uri)
          respond(message[:id], SWALLOWED_REQUESTS[method])
        else
          track_request(message)
          forward_to_server(message)
        end
      end
    end

    def handle_initialize(message)
      params = (message[:params] || {}).dup
      options = (params[:initializationOptions] || {}).dup
      command = resolve_ruby_lsp_command(options.delete(:rubyLspCommand))

      @supports_pull_diagnostics = !params.dig(:capabilities, :textDocument, :diagnostic).nil?

      # Formatting and linting run against the shadow would be meaningless, so
      # don't make ruby-lsp load RuboCop unless the user explicitly asks.
      options[:formatter] ||= "none"
      options[:linters] ||= []
      params[:initializationOptions] = options

      begin
        spawn_ruby_lsp(command)
      rescue SystemCallError => e
        respond_error(message[:id], "haml-lsp could not start ruby-lsp (#{command.shelljoin}): #{e.message}. " \
                                    "Install it with `gem install ruby-lsp` or configure `rubyLspCommand`.")
        @exiting = true
        return
      end

      track_request(message)
      forward_to_server(message.merge(params: params))
    end

    def did_open(message)
      params = message[:params]
      text_document = params[:textDocument]
      return forward_to_server(message) unless haml_document?(text_document)

      document = Document.new(
        uri: text_document[:uri],
        source: text_document[:text].to_s,
        version: text_document[:version],
        encoding: @encoding,
      )
      @documents[text_document[:uri]] = document

      forward_to_server(message.merge(
        params: params.merge(textDocument: text_document.merge(languageId: RUBY_LANGUAGE_ID, text: document.ruby)),
      ))
      publish_diagnostics(document) unless @supports_pull_diagnostics
    end

    def did_change(message)
      params = message[:params]
      text_document = params[:textDocument]
      document = @documents[text_document[:uri]]
      return forward_to_server(message) unless document

      previous_ruby = document.ruby
      document.apply_changes(params[:contentChanges] || [], version: text_document[:version])

      change = ShadowDiff.change(previous_ruby, document.ruby, @encoding)
      forward_to_server(message.merge(params: params.merge(contentChanges: [change].compact)))
      publish_diagnostics(document) unless @supports_pull_diagnostics
    end

    def did_close(message)
      @documents.delete(message.dig(:params, :textDocument, :uri))
      forward_to_server(message)
    end

    def diagnostic(message)
      document = @documents[message.dig(:params, :textDocument, :uri)]
      unless document
        track_request(message)
        return forward_to_server(message)
      end

      respond(message[:id], { kind: "full", items: Diagnostics.for(document) })
    end

    def completion(message)
      document, position = document_and_position(message)
      return passthrough(message) if document.nil? || document.ruby_at?(position[:line], position[:character])

      respond(message[:id], HamlCompletion.items(document, position[:line], position[:character]))
    end

    def completion_item_resolve(message)
      if message.dig(:params, :data, :hamlLsp)
        respond(message[:id], message[:params])
      else
        passthrough(message)
      end
    end

    def ruby_only_request(message)
      document, position = document_and_position(message)
      return passthrough(message) if document.nil? || document.ruby_at?(position[:line], position[:character])

      respond(message[:id], nil)
    end

    def document_and_position(message)
      params = message[:params] || {}
      [@documents[params.dig(:textDocument, :uri)], params[:position] || {}]
    end

    def passthrough(message)
      track_request(message)
      forward_to_server(message)
    end

    def publish_diagnostics(document)
      @client.write(
        jsonrpc: "2.0",
        method: "textDocument/publishDiagnostics",
        params: { uri: document.uri, version: document.version, diagnostics: Diagnostics.for(document) },
      )
    end

    def haml_document?(text_document)
      text_document[:languageId] == HAML_LANGUAGE_ID || text_document[:uri].to_s.end_with?(".haml")
    end

    # ------------------------------------------------------------------
    # Server -> client
    # ------------------------------------------------------------------

    def server_loop
      while (message = @server.read)
        handle_server_message(message)
      end
      log("ruby-lsp closed its output")
      child_exited!
    rescue Transport::ClosedError
      # The client went away; the main loop is winding down.
    rescue StandardError => e
      log("error while relaying ruby-lsp message: #{e.full_message}")
      child_exited!
    end

    def child_exited!
      return if @exiting

      @exiting = true
      @main_thread.raise(ChildExited)
    end

    def handle_server_message(message)
      debug("server -> ", message)

      if message[:method].nil? && message.key?(:id)
        pending = @pending_lock.synchronize { @pending.delete(message[:id]) }
        message = post_process_response(message, pending) if pending
      end

      @client.write(message)
    end

    def post_process_response(message, pending)
      case pending[:method]
      when "initialize" then patch_initialize_result(message)
      else message
      end
    end

    def patch_initialize_result(message)
      result = message[:result]
      return message unless result.is_a?(Hash)

      capabilities = result[:capabilities] || {}
      @encoding = PositionEncoding.from_lsp(capabilities[:positionEncoding])

      capabilities[:documentFormattingProvider] = false
      capabilities[:documentRangeFormattingProvider] = false
      capabilities[:codeActionProvider] = false
      capabilities.delete(:documentOnTypeFormattingProvider)
      capabilities[:diagnosticProvider] ||= { interFileDependencies: false, workspaceDiagnostics: false }

      completion = capabilities[:completionProvider] ||= {}
      completion[:triggerCharacters] = (Array(completion[:triggerCharacters]) | HAML_TRIGGER_CHARACTERS)

      result[:capabilities] = capabilities
      result[:serverInfo] = {
        name: "haml-lsp",
        version: "#{VERSION} (ruby-lsp #{result.dig(:serverInfo, :version)})",
      }
      message
    end

    # ------------------------------------------------------------------
    # Plumbing
    # ------------------------------------------------------------------

    def track_request(message)
      return unless message.key?(:id)

      @pending_lock.synchronize do
        @pending[message[:id]] = { method: message[:method], uri: message.dig(:params, :textDocument, :uri) }
      end
    end

    def forward_to_server(message)
      unless @server
        log("dropping #{message[:method]} received before ruby-lsp was started")
        return
      end

      @server.write(message)
    rescue Transport::ClosedError
      raise ChildExited
    end

    def respond(id, result)
      @client.write(jsonrpc: "2.0", id: id, result: result)
    end

    def respond_error(id, text, code: INTERNAL_ERROR)
      log(text)
      @client.write(jsonrpc: "2.0", id: id, error: { code: code, message: text })
    end

    def notify_client_error(text)
      log(text)
      @client.write(jsonrpc: "2.0", method: "window/showMessage", params: { type: MESSAGE_TYPE_ERROR, message: text })
    rescue Transport::ClosedError
      nil
    end

    def resolve_ruby_lsp_command(option)
      command = option || @ruby_lsp_command || ENV.fetch("HAML_LSP_RUBY_LSP_COMMAND", nil)

      case command
      when Array then command.map(&:to_s)
      when String then Shellwords.split(command)
      else default_ruby_lsp_command
      end
    end

    def default_ruby_lsp_command
      lockfile = File.join(Dir.pwd, "Gemfile.lock")
      if File.file?(lockfile) && File.read(lockfile).match?(/^    ruby-lsp \(/)
        %w[bundle exec ruby-lsp]
      else
        %w[ruby-lsp]
      end
    end

    def spawn_ruby_lsp(command)
      log("starting ruby-lsp: #{command.shelljoin}")

      stdin, stdout, stderr, @child = with_clean_bundler_env(command) { Open3.popen3(*command) }
      @child_stdin = stdin
      @server = Transport.new(stdout, stdin)

      Thread.new do
        stderr.each_line { |line| @log_io.print("[ruby-lsp] #{line}") }
      rescue IOError
        nil
      end

      @server_thread = Thread.new { server_loop }
    end

    # When haml-lsp runs under `bundle exec` but ruby-lsp is not part of that
    # bundle, the inherited Bundler environment would prevent ruby-lsp from
    # loading its own gems.
    def with_clean_bundler_env(command, &block)
      if defined?(::Bundler) && command.first != "bundle"
        ::Bundler.with_original_env(&block)
      else
        yield
      end
    end

    def shutdown_child
      return unless @child

      @child_stdin.close unless @child_stdin.closed?

      unless @child.join(3)
        pid = @child.pid
        log("ruby-lsp did not exit in time; terminating pid #{pid}")
        Process.kill("TERM", pid)
        @child.join(2) || Process.kill("KILL", pid)
      end
    rescue Errno::ESRCH, Errno::ECHILD, IOError, ChildExited
      nil
    end

    def log(text)
      @log_io.puts("[haml-lsp] #{text}")
      @log_io.flush
    rescue IOError
      nil
    end

    def debug(prefix, message)
      return unless @debug

      log("#{prefix}#{message[:method] || "response"} #{message[:id].inspect}")
    end
  end
end
