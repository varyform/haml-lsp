# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "timeout"

class ServerTest < Minitest::Test
  FAKE_RUBY_LSP = [RbConfig.ruby, File.expand_path("support/fake_ruby_lsp.rb", __dir__)].freeze
  URI = "file:///app/views/users/show.html.haml"

  def setup
    @client_to_server_r, @client_to_server_w = IO.pipe
    @server_to_client_r, @server_to_client_w = IO.pipe
    @log = StringIO.new
    @server = HamlLsp::Server.new(
      input: @client_to_server_r,
      output: @server_to_client_w,
      error: @log,
      ruby_lsp_command: FAKE_RUBY_LSP,
    )
    @server_thread = Thread.new { @server.run }
    @client = HamlLsp::Transport.new(@server_to_client_r, @client_to_server_w)
    @next_id = 0
  end

  def teardown
    @client_to_server_w.close unless @client_to_server_w.closed?
    @server_thread.join(5)
    [@client_to_server_r, @server_to_client_r, @server_to_client_w].each { |io| io.close unless io.closed? }
  end

  def test_initialize_patches_capabilities_and_forwards_options
    # `rubyLspCommand` is consumed by haml-lsp (and takes precedence over the CLI flag); the rest is ruby-lsp's.
    response = initialize!(initialization_options: { rubyLspCommand: FAKE_RUBY_LSP, enabledFeatures: { hover: true } })
    result = response[:result]
    capabilities = result[:capabilities]

    assert_equal false, capabilities[:documentFormattingProvider]
    assert_equal false, capabilities[:documentRangeFormattingProvider]
    assert_equal false, capabilities[:codeActionProvider]
    assert_nil capabilities[:documentOnTypeFormattingProvider]
    assert capabilities[:hoverProvider]
    assert capabilities[:diagnosticProvider]
    assert_equal "haml-lsp", result[:serverInfo][:name]
    assert_match(/ruby-lsp 9\.9\.9/, result[:serverInfo][:version])

    forwarded = result[:initializationOptions]
    assert_nil forwarded[:rubyLspCommand]
    assert_equal({ hover: true }, forwarded[:enabledFeatures])
    assert_equal "none", forwarded[:formatter]
    assert_equal [], forwarded[:linters]
  end

  def test_server_initiated_messages_reach_the_client_and_responses_go_back
    initialize!

    request = read_until { |m| m[:method] == "window/workDoneProgress/create" }
    assert_equal "fake-req-1", request[:id]

    log_message = read_until { |m| m[:method] == "window/logMessage" }
    assert_equal "fake ruby-lsp ready", log_message[:params][:message]

    # The client's reply must be relayed without haml-lsp choking on a message without a method.
    @client.write(jsonrpc: "2.0", id: "fake-req-1", result: nil)
    assert_equal({ echo: "ping", params: {} }, request!("ping", {})[:result])
  end

  def test_haml_document_is_opened_as_its_ruby_shadow
    initialize!
    open!("%h1= @user.name\n- if admin?\n  %p Admin\n")

    documents = request!("fake/documents", {})[:result]
    doc = documents[URI.to_sym]
    assert_equal "ruby", doc[:languageId]
    assert_equal "   ; @user.name\n  if admin?\n          ; end\n", doc[:text]
  end

  def test_non_haml_documents_pass_through_untouched
    initialize!
    uri = "file:///app/models/user.rb"
    @client.write(
      jsonrpc: "2.0",
      method: "textDocument/didOpen",
      params: { textDocument: { uri: uri, languageId: "ruby", version: 1, text: "class User; end\n" } },
    )

    doc = request!("fake/documents", {})[:result][uri.to_sym]
    assert_equal "class User; end\n", doc[:text]
  end

  def test_incremental_edits_are_applied_to_haml_and_the_shadow_is_resent
    initialize!
    open!("%p= foo\n%p\n")

    # Type "_bar" after "foo".
    change!(2, [{ range: range(0, 7, 0, 7), text: "_bar" }])
    doc = request!("fake/documents", {})[:result][URI.to_sym]
    assert_equal "  ; foo_bar\n  \n", doc[:text]
    assert_equal 2, doc[:version]

    # Now turn the second line into a block with a child, which appends an `end`
    # past the end of a line and changes the shadow's length.
    change!(3, [{ range: range(1, 0, 1, 2), text: "- items.each do |i|\n  = i" }])
    doc = request!("fake/documents", {})[:result][URI.to_sym]
    assert_equal "  ; foo_bar\n  items.each do |i|\n    i; end\n", doc[:text]

    # And delete the child again so the shadow shrinks.
    change!(4, [{ range: range(1, 19, 2, 5), text: "" }])
    doc = request!("fake/documents", {})[:result][URI.to_sym]
    assert_equal "  ; foo_bar\n  items.each do |i|\n", doc[:text]
  end

  def test_positions_line_up_between_haml_and_shadow
    initialize!
    open!("%section.hero{ class: css }\n  %h2= greeting_for(current_user)\n")

    hover = request!("textDocument/hover", textDocument: { uri: URI }, position: { line: 1, character: 8 })
    assert_equal "     ; greeting_for(current_user)", hover[:result][:contents]
  end

  def test_formatting_and_code_actions_are_answered_locally_for_haml
    initialize!
    open!("%p\n")

    assert_nil request!("textDocument/formatting", textDocument: { uri: URI }, options: {})[:result]
    assert_nil request!("textDocument/rangeFormatting", textDocument: { uri: URI }, range: range(0, 0, 0, 1))[:result]
    assert_nil request!("textDocument/onTypeFormatting", textDocument: { uri: URI }, ch: "\n")[:result]
    assert_equal [], request!("textDocument/codeAction", textDocument: { uri: URI }, range: range(0, 0, 0, 1))[:result]
  end

  def test_completion_trigger_characters_include_haml_sigils
    capabilities = initialize![:result][:capabilities]
    assert_equal %w[. % : !], capabilities[:completionProvider][:triggerCharacters]
  end

  def test_semantic_token_deltas_are_disabled
    capabilities = initialize![:result][:capabilities]
    assert_equal true, capabilities[:semanticTokensProvider][:full]
    assert_equal true, capabilities[:semanticTokensProvider][:range]
  end

  def test_response_positions_are_clamped_to_the_template
    initialize!
    open!("- if a\n  = b\n")

    # The fake folds to the end of the shadow line `    b; end` (10); the template line `  = b` is 5 long.
    folds = request!("textDocument/foldingRange", textDocument: { uri: URI })[:result]
    assert_equal [{ startLine: 0, startCharacter: 0, endLine: 1, endCharacter: 5, kind: "region" }], folds
  end

  def test_ruby_requests_in_markup_are_answered_locally
    initialize!
    open!("%p Hello \#{name}\n")

    # In plain text: no round trip, empty answers.
    assert_nil request!("textDocument/hover", textDocument: { uri: URI }, position: { line: 0, character: 4 })[:result]
    assert_nil request!("textDocument/definition", textDocument: { uri: URI }, position: { line: 0, character: 4 })[:result]
    assert_nil request!("textDocument/signatureHelp", textDocument: { uri: URI }, position: { line: 0, character: 4 })[:result]

    # Inside the interpolation: forwarded to ruby-lsp (the fake answers hover with the shadow line).
    hover = request!("textDocument/hover", textDocument: { uri: URI }, position: { line: 0, character: 12 })
    assert_equal "           name;", hover[:result][:contents]
  end

  def test_completion_offers_haml_syntax_in_markup_and_ruby_otherwise
    initialize!
    open!("%di\n= foo.ba\n")

    haml = request!("textDocument/completion", textDocument: { uri: URI }, position: { line: 0, character: 3 })
    assert_includes haml[:result][:items].map { |i| i[:label] }, "div"

    ruby = request!("textDocument/completion", textDocument: { uri: URI }, position: { line: 1, character: 8 })
    assert_equal "textDocument/completion", ruby[:result][:echo]
  end

  def test_resolving_a_haml_completion_item_returns_it_unchanged
    initialize!
    item = { label: "div", kind: 14, data: { hamlLsp: true } }

    assert_equal item, request!("completionItem/resolve", item)[:result]
    assert_equal "completionItem/resolve", request!("completionItem/resolve", { label: "x" })[:result][:echo]
  end

  def test_diagnostics_for_haml_come_from_the_haml_parser
    initialize!
    open!("%div\n  %p\n %span\n")

    result = request!("textDocument/diagnostic", textDocument: { uri: URI })[:result]
    assert_equal "full", result[:kind]
    assert_equal 1, result[:items].size
    assert_equal "haml", result[:items].first[:source]
    assert_equal 2, result[:items].first[:range][:start][:line]

    # Fix the indentation and the diagnostic goes away.
    change!(2, [{ range: range(2, 0, 2, 1), text: "  " }])
    result = request!("textDocument/diagnostic", textDocument: { uri: URI })[:result]
    assert_empty result[:items]
  end

  def test_diagnostics_for_other_documents_are_forwarded
    initialize!
    uri = "file:///app/models/user.rb"
    @client.write(
      jsonrpc: "2.0",
      method: "textDocument/didOpen",
      params: { textDocument: { uri: uri, languageId: "ruby", version: 1, text: "" } },
    )

    result = request!("textDocument/diagnostic", textDocument: { uri: uri })[:result]
    assert_equal [{ message: "from ruby-lsp" }], result[:items]
  end

  def test_diagnostics_are_pushed_when_the_client_cannot_pull
    initialize!(capabilities: { textDocument: {} })
    open!("%div\n  %p\n %span\n")

    published = read_until { |m| m[:method] == "textDocument/publishDiagnostics" }
    assert_equal URI, published[:params][:uri]
    assert_equal 1, published[:params][:diagnostics].size
  end

  def test_closing_a_document_forgets_it
    initialize!
    open!("%p\n")
    @client.write(jsonrpc: "2.0", method: "textDocument/didClose", params: { textDocument: { uri: URI } })

    # Once closed, formatting is no longer swallowed and reaches the fake, which echoes it.
    result = request!("textDocument/formatting", textDocument: { uri: URI }, options: {})[:result]
    assert_equal "textDocument/formatting", result[:echo]
  end

  def test_shutdown_and_exit
    initialize!
    assert_nil request!("shutdown", nil)[:result]
    @client.write(jsonrpc: "2.0", method: "exit")

    assert_equal 0, @server_thread.value
  end

  def test_unstartable_ruby_lsp_reports_an_error
    @client_to_server_w.close
    @server_thread.join(5)

    r, w = IO.pipe
    out_r, out_w = IO.pipe
    server = HamlLsp::Server.new(input: r, output: out_w, error: StringIO.new, ruby_lsp_command: ["definitely-not-a-real-ruby-lsp"])
    thread = Thread.new { server.run }
    client = HamlLsp::Transport.new(out_r, w)
    client.write(jsonrpc: "2.0", id: 1, method: "initialize", params: { capabilities: {} })

    response = Timeout.timeout(5) { client.read }
    assert_match(/could not start ruby-lsp/, response[:error][:message])
    w.close
    thread.join(5)
  end

  private

  def initialize!(initialization_options: {}, capabilities: { textDocument: { diagnostic: {} } })
    request!("initialize", capabilities: capabilities, initializationOptions: initialization_options)
  end

  def open!(text)
    @client.write(
      jsonrpc: "2.0",
      method: "textDocument/didOpen",
      params: { textDocument: { uri: URI, languageId: "haml", version: 1, text: text } },
    )
  end

  def change!(version, changes)
    @client.write(
      jsonrpc: "2.0",
      method: "textDocument/didChange",
      params: { textDocument: { uri: URI, version: version }, contentChanges: changes },
    )
  end

  def request!(method, params)
    id = (@next_id += 1)
    @client.write(jsonrpc: "2.0", id: id, method: method, params: params)
    read_until { |message| message[:id] == id && !message.key?(:method) }
  end

  def read_until
    Timeout.timeout(5) do
      loop do
        message = @client.read
        flunk("connection closed while waiting for a message\n#{@log.string}") if message.nil?
        return message if yield(message)
      end
    end
  end

  def range(start_line, start_char, end_line, end_char)
    { start: { line: start_line, character: start_char }, end: { line: end_line, character: end_char } }
  end
end
