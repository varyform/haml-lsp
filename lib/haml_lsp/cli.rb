# frozen_string_literal: true

require "optparse"

module HamlLsp
  class CLI
    def self.run(argv, stdout: $stdout)
      new(argv, stdout: stdout).run
    end

    def initialize(argv, stdout:)
      @argv = argv
      @stdout = stdout
      @options = { encoding: PositionEncoding::UTF16 }
    end

    def run
      parser.parse!(@argv)

      if @options[:extract]
        extract
        0
      else
        Server.new(ruby_lsp_command: @options[:ruby_lsp_command]).run
      end
    rescue OptionParser::ParseError => e
      warn(e.message)
      warn(parser)
      2
    end

    private

    def parser
      @parser ||= OptionParser.new do |opts|
        opts.banner = <<~BANNER
          Usage: haml-lsp [options]

          Starts the HAML language server on stdin/stdout (the LSP transport
          editors use). ruby-lsp is spawned as a child process.

          Options:
        BANNER

        opts.on("--ruby-lsp-command COMMAND", "Command used to start ruby-lsp " \
                                              "(default: `bundle exec ruby-lsp` when the Gemfile.lock " \
                                              "contains ruby-lsp, otherwise `ruby-lsp`).") do |command|
          @options[:ruby_lsp_command] = command
        end

        opts.on("--extract [FILE]", "Debug: print the Ruby shadow for a HAML file (or stdin) and exit.") do |file|
          @options[:extract] = file || "-"
        end

        opts.on("--encoding ENCODING", %w[utf-8 utf-16 utf-32],
                "Position encoding used by --extract (utf-8, utf-16, utf-32).") do |encoding|
          @options[:encoding] = encoding
        end

        opts.on("-v", "--version", "Print the version and exit.") do
          @stdout.puts(VERSION)
          exit 0
        end

        opts.on("-h", "--help", "Show this help.") do
          @stdout.puts(opts)
          exit 0
        end
      end
    end

    def extract
      source = @options[:extract] == "-" ? $stdin.read : File.read(@options[:extract])
      encoding = PositionEncoding.new(@options[:encoding])
      @stdout.print(RubyExtractor.extract(source, encoding: encoding))
      @stdout.print("\n") unless source.end_with?("\n")
    end
  end
end
