# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"

# Copies upstream SQL verbatim. --check verifies both file names and bytes.
check = ARGV.delete("--check")
pro = ARGV.delete("--pro")

source = File.expand_path(ARGV.fetch(0))
root = File.expand_path("..", __dir__)
destination = pro ? File.join(root, "pro/riverqueue-pro/migration") : File.join(root, "migration")
line = pro ? "pro" : "main"
drivers = pro ? {"postgresql" => "driver/riverpropgxv5", "sqlite" => "driver/riverprosqlite"} :
  {"postgresql" => "riverdriver/riverpgxv5", "sqlite" => "riverdriver/riversqlite"}

files = {}
drivers.each do |backend, directory|
  upstream = Dir.glob(File.join(source, directory, "migration", line, "*.sql")).sort
  abort "No migrations found for #{backend}" if upstream.empty?

  upstream.each do |path|
    relative = File.join(backend, line, File.basename(path))
    target = File.join(destination, relative)

    if check
      abort "Migration differs: #{relative}" unless File.file?(target) && File.binread(target) == File.binread(path)
    else
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(path, target)
    end

    files[relative] = Digest::SHA256.file(path).hexdigest
  end
end

extra = Dir.glob(File.join(destination, "**/*.sql")).map { |path| path.delete_prefix("#{destination}/") } - files.keys
abort "Unexpected migrations: #{extra.join(", ")}" unless extra.empty?

unless pro
  license = File.join(source, "LICENSE")
  target = File.join(destination, "LICENSE")

  if check
    abort "Upstream migration license differs" unless File.binread(target) == File.binread(license)
  else
    FileUtils.cp(license, target)
  end
end

revision, status = Open3.capture2("git", "-C", source, "rev-parse", "HEAD")
abort "Cannot resolve upstream revision" unless status.success?

manifest = {"files" => files, "repository" => pro ? "riverpro" : "river", "revision" => revision.strip}
manifest_path = File.join(destination, "manifest.json")
if check
  abort "Manifest differs" unless JSON.parse(File.read(manifest_path)) == manifest
else
  File.write(manifest_path, JSON.pretty_generate(manifest) + "\n")
end

puts "#{check ? "Verified" : "Copied"} #{files.size} #{line} migration files at #{revision.strip}"
