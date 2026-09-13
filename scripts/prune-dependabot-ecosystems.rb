#!/usr/bin/env ruby
# SPDX-License-Identifier: MPL-2.0
# Keep only explicitly selected Dependabot ecosystems after project minting.
# Nix is not a valid Dependabot ecosystem. Refuse to empty the updates list.
abort 'Usage: prune-dependabot-ecosystems.rb <file> <keep...>' if ARGV.length < 2
path = ARGV.shift
keep = ARGV - ['nix']
unless File.file?(path)
  puts "  dependabot: #{path} absent, nothing to prune"
  exit 0
end
text = File.read(path, encoding: 'UTF-8')
parts = text.split(/^(?=[ \t]*-[ \t]*package-ecosystem:)/)
head = parts.shift || ''
entries = parts.map { |entry| [entry[/package-ecosystem:[ \t]*["']?([A-Za-z-]+)/, 1] || '?', entry] }
kept, dropped = entries.partition { |name, _entry| keep.include?(name) }
if entries.empty?
  puts '  dependabot: no ecosystem entries found'
elsif kept.empty?
  puts '  dependabot: refusing to prune every entry; left unchanged'
elsif dropped.empty?
  puts '  dependabot: nothing to prune'
else
  File.write(path, head + kept.map(&:last).join)
  puts "  dependabot: kept #{kept.map(&:first).join(', ')} / dropped #{dropped.map(&:first).join(', ')}"
end
