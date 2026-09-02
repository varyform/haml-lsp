# frozen_string_literal: true

require_relative "lib/haml_lsp/version"

Gem::Specification.new do |spec|
  spec.name = "haml-lsp"
  spec.version = HamlLsp::VERSION
  spec.authors = [ "Oleh" ]
  spec.summary = "Language server for HAML templates, powered by ruby-lsp"
  spec.description = <<~DESC
    haml-lsp brings Ruby intelligence (hover, go-to-definition, completion, signature help, ...)
    to HAML templates. It extracts the Ruby embedded in a .haml file into a position-preserving
    Ruby "shadow" document and delegates to ruby-lsp, while providing HAML-specific diagnostics itself.
  DESC
  spec.homepage = "https://github.com/olehsavchuk/haml-lsp"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md", "LICENSE.txt"]
  spec.bindir = "exe"
  spec.executables = [ "haml-lsp" ]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "haml", ">= 6.0"
  spec.add_dependency "prism", ">= 1.0"
end
