# frozen_string_literal: true

require_relative "haml_lsp/version"
require_relative "haml_lsp/position_encoding"
require_relative "haml_lsp/ruby_extractor"
require_relative "haml_lsp/document"
require_relative "haml_lsp/diagnostics"
require_relative "haml_lsp/transport"
require_relative "haml_lsp/server"
require_relative "haml_lsp/cli"

module HamlLsp
  class Error < StandardError; end
end
