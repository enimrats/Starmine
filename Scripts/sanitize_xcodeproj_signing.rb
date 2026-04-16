#!/usr/bin/env ruby
# frozen_string_literal: true

EMPTY_VALUES = ['""', '-', '"-"'].freeze

ASSIGNMENT_PATTERNS = [
  /(\s*"?(?:DEVELOPMENT_TEAM(?:_NAME)?|DevelopmentTeam(?:Name)?)"?\s*=\s*)(.+?)(;\s*)$/,
  /(\s*"?(?:PROVISIONING_PROFILE(?:_SPECIFIER)?|ProvisioningProfileSpecifier|SigningCertificate)"?\s*=\s*)(.+?)(;\s*)$/,
].freeze

CODE_SIGN_IDENTITY_PATTERN = /(\s*"?(?:CODE_SIGN_IDENTITY(?:\[[^\]]+\])?)"?\s*=\s*)(.+?)(;\s*)$/

def sanitize_assignment(line, pattern)
  line.sub(pattern) do
    %(#{Regexp.last_match(1)}""#{Regexp.last_match(3)})
  end
end

def sanitize_code_sign_identity(line)
  line.sub(CODE_SIGN_IDENTITY_PATTERN) do
    value = Regexp.last_match(2).strip
    if EMPTY_VALUES.include?(value)
      Regexp.last_match(0)
    else
      %(#{Regexp.last_match(1)}""#{Regexp.last_match(3)})
    end
  end
end

def sanitize_content(content)
  content.each_line.map do |line|
    sanitized = ASSIGNMENT_PATTERNS.reduce(line) do |current, pattern|
      sanitize_assignment(current, pattern)
    end

    sanitize_code_sign_identity(sanitized)
  end.join
end

if ARGV.empty?
  $stdout.write(sanitize_content($stdin.read))
  exit 0
end

ARGV.each do |path|
  original = File.read(path)
  sanitized = sanitize_content(original)
  next if sanitized == original

  File.write(path, sanitized)
end
