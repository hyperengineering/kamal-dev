# frozen_string_literal: true

source "https://rubygems.org"

# Custom gem source for Ruby 3.4 compatible bcrypt_pbkdf
source "https://gem.fury.io/reforge/" do
  gem "bcrypt_pbkdf", "1.1.4"
end

# Specify your gem's dependencies in kamal-dev.gemspec
gemspec

# Development: ensure our gem is auto-required when running kamal commands
require_relative "lib/kamal-dev"

gem "irb"
gem "rake", "~> 13.0"

gem "rspec", "~> 3.0"

gem "standard", "~> 1.3"
