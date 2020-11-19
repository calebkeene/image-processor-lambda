
# run locally to validate version (dimension) types before upload
raise "usage ruby version_counter.rb PATH_TO_PHOTOS" if ARGV.empty?

photos_path = ARGV[0]

puts "inspecting photos in #{photos_path}"

photos = Dir["#{photos_path}/*.jpg"]
puts "loaded #{photos.count} photos"

version_counts = {
  "4x5" => 0,
  "4x4" => 0,
  "5x4" => 0
}

ratio_mappings = {
  "0.8"  => "4x5",
  "1.0"  => "4x4",
  "1.25" => "5x4"
}


photos.each do |photo_path|
  identify_command = "magick identify #{photo_path} | awk '{print $3}'"
  width, height = `#{identify_command}`.chomp.split("x").map(&:to_f)
  puts "width: #{width}, height: #{height}"

  ratio = (width/height).round(2).to_s
  puts "ratio: #{ratio}\n"

  version_key = ratio_mappings[ratio]

  if version_key.nil?
    filename = photo_path.split("/").last

    puts "ERROR: incorrect processed version '#{filename}', skipping"
    next
  end

  version_counts[version_key] += 1
end

puts "finished counting, displaying version counts"
puts version_counts.inspect