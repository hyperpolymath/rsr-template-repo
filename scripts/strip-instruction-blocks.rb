#!/usr/bin/env ruby
# SPDX-License-Identifier: MPL-2.0
# Remove only HTML comments containing TEMPLATE INSTRUCTIONS after minting.
# The tempered match cannot cross a preceding SPDX comment's terminator.
require 'find'
root = ARGV.fetch(0, '.')
marker = 'TEMPLATE INSTRUCTIONS'
block = /<!--(?:(?!-->).)*?#{Regexp.escape(marker)}(?:(?!-->).)*?-->[ \t]*\n?/m
skip_dirs = %w[.git node_modules .venv target dist]
changed = 0
Find.find(root) do |path|
  if File.directory?(path) && skip_dirs.include?(File.basename(path))
    Find.prune
  end
  next if File.symlink?(path) || !File.file?(path)
  begin
    text = File.read(path, encoding: 'UTF-8')
  rescue SystemCallError
    next
  end
  next unless text.valid_encoding? && text.include?(marker)
  updated = text.gsub(block, '')
  next if updated == text
  File.write(path, updated.gsub(/\n{3,}/, "\n\n"))
  puts "  instruction block: stripped from #{path}"
  changed += 1
end
puts changed.positive? ? "  instruction blocks: #{changed} file(s) cleaned" : '  instruction blocks: none found'
