# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'aws-sdk-s3'

# ASSUMPTIONS
# imagemagick binary is loaded in lambda layer

class ImageProcessorLambda
  class << self
    TMP_IMAGE_BASE_PATH = "/tmp/processed"

    # only doing thumbnails for now, but keep the API flexible (may process other versions in the future)
    RESIZE_VERSIONS = {
      thumbnail: 400
    }.freeze

    RATIO_LABELS = {
      "0.8"  => "portrait",
      "1.0"  => "square",
      "1.25" => "landscape"
    }.freeze

    def generate_versions(event:, context:)
      record = event['Records'].first

      @bucket_info = record.dig('s3', 'bucket')
      @object_info = record.dig('s3', 'object')

      # get photo from s3 and save to tmp filesystem for manipulation
      download_file
      puts "base_photo_path => #{base_photo_path}"
      
      # skip generating the version if the file download somehow failed
      return if base_photo_path.nil?
      
      puts "creating directory: #{TMP_IMAGE_BASE_PATH}"
      FileUtils.mkpath(TMP_IMAGE_BASE_PATH)
      
      RESIZE_VERSIONS.keys.each do |version|
        processed_photo_path = run_magick(version)
        
        upload_to_public_bucket(processed_photo_path) if processed_photo_path
      end
    rescue StandardError => e
      puts "ERROR: #{e.inspect}"
    end

    private

    attr_reader :base_photo_path, :bucket_info, :object_info

    def upload_to_public_bucket(photo_path)
      destination_bucket_key = filename_from_path(photo_path)
      puts "uploading '#{destination_bucket_key}' to public bucket"

      public_s3_bucket.object(destination_bucket_key).upload_file(photo_path)

      puts "finished upload of #{destination_bucket_key}, cleaning up tmp file"
    ensure
      FileUtils.rm_f(photo_path)
    end

    def run_magick(version)
      puts "creating #{version} version"
      processed_photo_path = new_version_filepath(version)
      puts "processed_photo_path: #{processed_photo_path}"

      shell_command = %W[
        magick
        #{base_photo_path}
        -resize
        #{resize_dimensions(version)}
        #{processed_photo_path}
      ].join(' ')

      run_shell_command(shell_command)

      puts "checking existance of: #{processed_photo_path}"
      
      if File.exist?(processed_photo_path)
        puts "successfully processed #{processed_photo_path}"
        processed_photo_path
      else
        puts "ERROR: creating processed version '#{processed_photo_path}' failed, skipping upload to public bucket"
      end
    end

    def resize_dimensions(version)
      identify_command = "magick identify #{base_photo_path} | awk '{print $3}'"
      original_width = run_shell_command(identify_command).chomp.split('x')[0].to_f

      resize_width = RESIZE_VERSIONS[version]

      resize_percentage = ((resize_width / original_width) * 100).round(4)
      puts "resizing to: #{resize_percentage}%"
      "#{resize_percentage}%"
    end

    def new_version_filepath(version)
      base_filename, extension = base_filename_and_extension(
        filename_from_path(base_photo_path)
      )

      puts "base_filename: #{base_filename}"
      puts "'#{extension}' file detected"

      "#{TMP_IMAGE_BASE_PATH}/#{base_filename}-#{ratio_identifier}-#{version}#{extension}"
    end

    def filename_from_path(photo_path)
      photo_path.split('/').last
    end

    def ratio_identifier
      puts "identifying image ratio for #{base_photo_path}..."
      identify_command = "magick identify #{base_photo_path} | awk '{print $3}'"

      width, height = `#{identify_command}`.chomp.split("x").map(&:to_f)
      puts "width: #{width}, height: #{height}"

      ratio = (width/height).round(2).to_s
      puts "ratio: #{ratio}\n"

      label = RATIO_LABELS[ratio]

      puts "returning label: #{label}"
      label
    end

    def base_filename_and_extension(filename)
      extension = File.extname(filename)

      [File.basename(filename, extension), extension]
    end

    def run_shell_command(command_string)
      puts "running shell command: #{command_string}"

      `#{command_string} 2>&1`
    end

    def download_file
      filename = object_info['key'].split('/').last
      tmp_filepath = "/tmp/#{filename}"

      puts "downloading #{filename} to #{tmp_filepath}"

      File.open(tmp_filepath, 'wb') do |file|
        s3_client.get_object(
          {
            bucket: bucket_info['name'],
            key:    object_info['key']
          },
          target: file
        )
      end

      if File.exist?(tmp_filepath)
        puts "successful download"
        @base_photo_path = tmp_filepath
      else
        puts "ERROR: failed to download #{object_info['key']} from private bucket"
      end
    end

    def s3_client
      @s3_client ||= Aws::S3::Client.new(region: ENV['AWS_REGION'])
    end

    def public_s3_bucket
      @public_s3_bucket ||= begin
        s3_resource = Aws::S3::Resource.new(client: s3_client)

        s3_resource.bucket('keenedreams-photos-public')
      end
    end
  end
end
