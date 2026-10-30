# frozen_string_literal: true

require_relative 'lib/rubycog/version'

Gem::Specification.new do |spec|
  spec.name = 'rubycog'
  spec.version = Rubycog::VERSION
  spec.authors = ['ShiningRay']
  spec.summary = 'A tiny Ruby agent with a terminal UI'
  spec.description = 'A minimal RubyLLM-powered agent with one eval tool and an interactive TUI.'
  spec.homepage = 'https://github.com/ShiningRay/rubycog'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.2'

  spec.files = Dir['lib/**/*.rb'] + %w[README.md LICENSE.txt]
  spec.bindir = 'bin'
  spec.executables = ['rubycog']
  spec.require_paths = ['lib']

  spec.add_dependency 'curses', '~> 1.7'
  spec.add_dependency 'dotenv', '~> 3.1'
  spec.add_dependency 'ruby_llm', '~> 2.1'
end
