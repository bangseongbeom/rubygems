#!/usr/bin/env ruby
# frozen_string_literal: true

#
# Test that YAMLSerializer can load gemspecs of the top N most downloaded gems
# from rubygems.org and all their transitive runtime dependencies.
#
# Usage:
#   ruby -I lib --disable-gems tool/test_yaml_serializer_with_popular_gems.rb [N]
#
# N defaults to 100. The script fetches the top N gems by download ranking,
# recursively resolves all runtime dependencies, then attempts to parse each
# gemspec with Gem::YAMLSerializer.load.
#

# Bootstrap local rubygems when run with --disable-gems
require "rubygems"

require "date"
require "net/http"
require "json"
require "set"
require "stringio"
require "zlib"
require "rubygems/package"
require "rubygems/yaml_serializer"
require "rubygems/safe_yaml"

PERMITTED_CLASSES = [
  Symbol, Time, Date,
  Gem::Dependency, Gem::Platform, Gem::Requirement,
  Gem::Specification, Gem::Version, Gem::Version::Requirement
].freeze
PERMITTED_SYMBOLS = %w[development runtime].freeze
def fetch_json(http, path)
  req = Net::HTTP::Get.new(path)
  req["Accept"] = "application/json"
  req["Connection"] = "keep-alive"
  resp = http.request(req)
  raise "HTTP #{resp.code}: #{path}" unless resp.is_a?(Net::HTTPSuccess)
  JSON.parse(resp.body)
end

def fetch_top_gems(http, count)
  gems = []
  page = 1

  while gems.size < count
    warn "  Fetching page #{page}..."
    data = fetch_json(http, "/api/v1/search.json?query=*&page=#{page}")
    break if data.empty?
    data.each {|g| gems << g["name"] }
    page += 1
  end

  gems.first(count)
end

def resolve_all_deps(http, top_gems)
  all = {} # name => {version:, deps: [names]}
  queue = top_gems.dup
  resolved = Set.new

  iteration = 0
  while queue.any?
    iteration += 1
    batch = queue.reject {|n| resolved.include?(n) }
    break if batch.empty?

    warn "  Iteration #{iteration}: #{batch.size} gems (resolved: #{resolved.size})..."

    batch.each do |name|
      version = nil
      platform = nil
      deps = begin
        data = fetch_json(http, "/api/v1/gems/#{name}.json")
        version = data["version"]
        platform = data["platform"]
        runtime = data.dig("dependencies", "runtime") || []
        runtime.map {|d| d["name"] }
      rescue StandardError => e
        warn "    Error fetching deps for #{name}: #{e.message}"
        []
      end

      resolved << name
      all[name] = { version: version, platform: platform, deps: deps }
      deps.each do |dep|
        queue << dep unless resolved.include?(dep) || queue.include?(dep)
      end
    end

    queue.reject! {|n| resolved.include?(n) }
  end

  all
end

def extract_metadata_from_gem(gem_io)
  tar = Gem::Package::TarReader.new(gem_io)
  tar.each_entry do |entry|
    case entry.full_name
    when "metadata.gz"
      return Gem::Util.gunzip(entry.read)
    when "metadata"
      return entry.read
    end
  end
  nil
end

def fetch_gemspec_yaml(name, version, platform)
  # Extract metadata.gz from the .gem file - the real YAML written by
  # `gem build` using whatever Ruby/Psych the author had at build time.
  # First check GEM_HOME/cache for a local copy, then fall back to download.
  return nil unless version

  gem_filename = if platform && platform != "ruby"
    "#{name}-#{version}-#{platform}.gem"
  else
    "#{name}-#{version}.gem"
  end

  # Try local cache in $GEM_HOME/cache
  gem_home = ENV["GEM_HOME"]
  if gem_home
    cache_path = File.join(gem_home, "cache", gem_filename)
    if File.exist?(cache_path)
      return File.open(cache_path, "rb") {|f| extract_metadata_from_gem(f) }
    end
  end

  # Download from rubygems.org
  uri = URI("https://rubygems.org/gems/#{gem_filename}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = 15
  http.read_timeout = 30
  resp = http.request(Net::HTTP::Get.new(uri))
  return nil unless resp.is_a?(Net::HTTPSuccess)

  extract_metadata_from_gem(StringIO.new(resp.body))
rescue StandardError => e
  warn "    Error fetching .gem for #{name}-#{version}: #{e.class}: #{e.message}"
  nil
end

def test_gemspecs(all_gems)
  pass = []
  fail_list = []
  skip = []

  all_gems.sort_by {|name, _| name }.each do |name, info|
    yaml = fetch_gemspec_yaml(name, info[:version], info[:platform])
    unless yaml
      skip << name
      warn "  #{name}... SKIP (could not fetch)"
      next
    end

    begin
      spec = Gem::YAMLSerializer.load(
        yaml,
        permitted_classes: PERMITTED_CLASSES,
        permitted_symbols: PERMITTED_SYMBOLS,
      )

      if spec.is_a?(Gem::Specification)
        pass << { name: spec.name, version: spec.version.to_s }
      else
        fail_list << { name: name, error: "returned #{spec.class}" }
        warn "  #{name}... FAIL (returned #{spec.class})"
      end
    rescue StandardError => e
      fail_list << { name: name, error: "#{e.class}: #{e.message}" }
      warn "  #{name}... FAIL (#{e.class}: #{e.message})"
    end
  end

  [pass.sort_by {|p| p[:name] }, fail_list.sort_by {|f| f[:name] }, skip.sort]
end

# --- Main ---

top_n = (ARGV[0] || 100).to_i

http = Net::HTTP.new("rubygems.org", 443)
http.use_ssl = true
http.open_timeout = 10
http.read_timeout = 10

begin
  http.start

  warn "Step 1: Fetching top #{top_n} gems from rubygems.org..."
  top_gems = fetch_top_gems(http, top_n)
  warn "  Got #{top_gems.size} gems"

  warn ""
  warn "Step 2: Resolving all transitive runtime dependencies..."
  all_gems = resolve_all_deps(http, top_gems)
  warn "  Total: #{all_gems.size} unique gems (#{top_gems.size} top + #{all_gems.size - top_gems.size} transitive deps)"
ensure
  begin
    http.finish
  rescue StandardError
    nil
  end
end

warn ""
warn "Step 3: Downloading .gem files and testing YAMLSerializer.load against #{all_gems.size} gemspecs..."
warn ""

pass, fail_list, skip = test_gemspecs(all_gems)

puts
puts "=" * 60
puts "Results: #{pass.size} passed, #{fail_list.size} failed, #{skip.size} skipped / #{all_gems.size} total"
puts

if pass.any?
  puts "Passed gems:"
  pass.each {|p| puts "  - #{p[:name]} #{p[:version]}" }
  puts
end

if fail_list.any?
  puts "Failed gems:"
  fail_list.each {|f| puts "  - #{f[:name]}: #{f[:error]}" }
  puts
end

if skip.any?
  puts "Skipped gems:"
  skip.each {|n| puts "  - #{n}" }
  puts
end

exit(fail_list.empty? ? 0 : 1)
