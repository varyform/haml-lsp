#!/usr/bin/env ruby
# frozen_string_literal: true

# A stand-in for ruby-lsp used by the proxy tests. It speaks just enough LSP
# to let the tests observe what the proxy sends:
#
#   * `initialize` answers with ruby-lsp-like capabilities
#   * documents are stored as received (text + languageId), edits are applied
#     the way ruby-lsp applies them (incremental, in the negotiated encoding)
#   * `textDocument/hover` returns the stored document's line at the position,
#     so a test can prove the proxy fed the shadow and positions line up
#   * `fake/documents` dumps the stored documents
#   * `textDocument/diagnostic` answers with a marker so the tests can tell
#     whether a request was forwarded or intercepted
#   * it echoes any other request back as its result
#   * `exit` terminates the process

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "haml_lsp/transport"
require "haml_lsp/position_encoding"

transport = HamlLsp::Transport.new($stdin, $stdout)
encoding = HamlLsp::PositionEncoding.new(HamlLsp::PositionEncoding::UTF16)
documents = {}

def respond(transport, id, result)
  transport.write(jsonrpc: "2.0", id: id, result: result)
end

while (message = transport.read)
  method = message[:method]
  params = message[:params] || {}
  id = message[:id]

  case method
  when "initialize"
    encoding = HamlLsp::PositionEncoding.new(ENV.fetch("FAKE_RUBY_LSP_ENCODING", "utf-16"))
    respond(transport, id, {
      capabilities: {
        positionEncoding: encoding.kind,
        textDocumentSync: { change: 2, openClose: true },
        hoverProvider: true,
        definitionProvider: true,
        documentFormattingProvider: true,
        documentRangeFormattingProvider: true,
        documentOnTypeFormattingProvider: { firstTriggerCharacter: "\n" },
        codeActionProvider: true,
        diagnosticProvider: { interFileDependencies: false, workspaceDiagnostics: false },
      },
      serverInfo: { name: "Ruby LSP", version: "9.9.9" },
      initializationOptions: params[:initializationOptions],
    })
    # Mimic ruby-lsp asking the client for something, to exercise the reverse path.
    transport.write(jsonrpc: "2.0", id: "fake-req-1", method: "window/workDoneProgress/create", params: { token: "x" })
    transport.write(jsonrpc: "2.0", method: "window/logMessage", params: { type: 3, message: "fake ruby-lsp ready" })
  when "textDocument/didOpen"
    td = params[:textDocument]
    documents[td[:uri]] = { text: td[:text].dup, languageId: td[:languageId], version: td[:version] }
  when "textDocument/didChange"
    td = params[:textDocument]
    doc = documents[td[:uri]]
    params[:contentChanges].each do |change|
      range = change[:range]
      start_offset = encoding.offset(doc[:text], range[:start][:line], range[:start][:character])
      end_offset = encoding.offset(doc[:text], range[:end][:line], range[:end][:character])
      doc[:text][start_offset...end_offset] = change[:text]
    end
    doc[:version] = td[:version]
  when "textDocument/didClose"
    documents.delete(params[:textDocument][:uri])
  when "textDocument/hover"
    doc = documents[params[:textDocument][:uri]]
    line = doc[:text].split("\n", -1)[params[:position][:line]]
    respond(transport, id, { contents: line })
  when "fake/documents"
    respond(transport, id, documents)
  when "textDocument/diagnostic"
    respond(transport, id, { kind: "full", items: [{ message: "from ruby-lsp" }] })
  when "shutdown"
    respond(transport, id, nil)
  when "exit"
    exit 0
  else
    respond(transport, id, { echo: method, params: params }) if id
  end
end
