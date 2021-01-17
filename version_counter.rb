
# run locally to validate version (dimension) types before upload
raise "usage ruby version_counter.rb PATH_TO_PHOTOS" if ARGV.empty?

photos_path = ARGV[0]

puts "inspecting photos in #{photos_path}"

photos = Dir["#{photos_path}/*.jpg"]
puts "loaded #{photos.count} photos"

aspect_group_counts = {
  "portrait" => 0,
  "square" => 0,
  "landscape" => 0
}

aspect_group_mappings = {
  "0.8"  => "portrait",
  "1.0"  => "square",
  "1.25" => "landscape"
}


photos.each do |photo_path|
  identify_command = "magick identify #{photo_path} | awk '{print $3}'"
  width, height = `#{identify_command}`.chomp.split("x").map(&:to_f)
  puts "width: #{width}, height: #{height}"

  ratio = (width/height).round(2).to_s
  puts "ratio: #{ratio}\n"

  version_key = aspect_group_mappings[ratio]

  if version_key.nil?
    filename = photo_path.split("/").last

    puts "ERROR: incorrect processed version '#{filename}', skipping"
    next
  end

  aspect_group_counts[version_key] += 1
end

puts "---------------------------------------------"
puts "finished counting, displaying version counts"
puts aspect_group_counts.inspect
puts "---------------------------------------------"
aspect_group_counts.each do |aspect_group, count|
  divisability_target = 3

  puts "checking divisability of #{aspect_group}"
  even_divisions, remainer = count.divmod(divisability_target)

  if remainer == 0
    puts "#{aspect_group} group evenly divisable by #{divisability_target}"
  else
    required_count = even_divisions * divisability_target
    puts "#{aspect_group} not divisible by #{divisability_target}, delete #{remainer} to have #{required_count} photos."

    next_divisability_target = count
    
    while next_divisability_target % 3 != 0
      next_divisability_target += 1
    end

    difference = next_divisability_target - count
    puts "or, you can add #{difference} photos to have #{next_divisability_target}"
  end
  puts "---------------------------------------------"
end