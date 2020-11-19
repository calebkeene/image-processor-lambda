# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'aws-sdk-s3'
require 'logger'

# ASSUMPTIONS
# imagemagick binary is loaded in lambda layer

class ImageProcessorLambda
  class << self
    VERSION_NAMES = %i[thumbnail medium].freeze

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
      @base_photo_path = download_file
      @new_versions_base_path = '/tmp/processed'
      
      puts "creating directory: #{new_versions_base_path}"
      FileUtils.mkpath(new_versions_base_path)

      @new_version_paths = []

      VERSION_NAMES.each_with_index do |version, version_index|
        run_magick(version)

        processed_photo_path = new_version_paths[version_index]
        puts "processed_photo_path = #{processed_photo_path}"

        upload_to_public_bucket(processed_photo_path)
      end
    end

    private

    attr_reader :base_photo_path, :new_versions_base_path, :bucket_info, :object_info
    attr_accessor :new_version_paths

    def upload_to_public_bucket(photo_path)
      puts "uploading #{photo_path}"

      destination_bucket_key = filename_from_path(photo_path)
      public_s3_bucket.object(destination_bucket_key).upload_file(photo_path)

      puts "finished upload of #{photo_path.split("/").last}, cleaning up tmp file"
    ensure
      FileUtils.rm_f(photo_path)
    end

    def run_magick(version)
      puts "processing version #{version}"
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
        puts 'file present!'
      else
        logger.error('file missing :<')
      end

      new_version_paths << processed_photo_path
    end

    def resize_dimensions(version)

      resize_width = version == :thumbnail ? 400.0 : 800.0
      
      # thumbnail - ensure 400px wide no matter the height
      # for medium, resize to double this (800px max width)
      # assumes this always be a shrink resize (source image is always mo re than 800px wide)

      identify_command = "magick identify #{base_photo_path} | awk '{print $3}'"
      original_width = run_shell_command(identify_command).chomp.split('x')[0].to_f

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

      "#{new_versions_base_path}/#{base_filename}-#{ratio_identifier}-#{version}#{extension}"
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
      else
        logger.error("error downloading #{object_info['key']} from private bucket")
      end

      tmp_filepath
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

    def logger
      @logger ||= Logger.new($stdout)
    end
  end
end
