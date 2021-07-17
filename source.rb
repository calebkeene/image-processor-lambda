# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'aws-sdk-s3'
require 'base64'
require 'net/http'

# ASSUMPTIONS
# imagemagick binary is loaded in lambda layer

class ImageProcessorLambda
  class << self
    TMP_IMAGE_BASE_PATH = "/tmp/processed"

    READABLE_ATTRIBUTES = %i(
      base_photo_path base_filename version processed_photo_path bucket_info object_info original_width original_height
    ).freeze

    # only doing thumbnails for now, but keep the API flexible (may process other versions in the future)
    RESIZE_VERSIONS = {
      thumbnail: 400
    }.freeze

    ASPECT_GROUP_MAPPINGS = {
      "0.8"  => "portrait",
      "1.0"  => "square",
      "1.25" => "landscape"
    }.freeze

    def generate_versions(event:, context:)
      reset_instance_variables

      record = event['Records'].first

      @bucket_info = record.dig('s3', 'bucket')
      @object_info = record.dig('s3', 'object')

      # get photo from s3 and save to tmp filesystem for manipulation
      download_photo
      puts "base_photo_path => #{base_photo_path}"
      
      # skip generating the version if the file download somehow failed
      if base_photo_path.nil?
        puts "failed to load photo (base_photo_path nil) - exiting"
        return
      end
      
      puts "creating directory: #{TMP_IMAGE_BASE_PATH}"
      FileUtils.mkpath(TMP_IMAGE_BASE_PATH)
      
      RESIZE_VERSIONS.keys.each do |version|
        @version = version

        original_photo_verbose_metadata # instantiate the instance variable and memoise it
        run_magick
        
        if processed_photo_path
          upload_to_public_bucket
          invoke_webhook
        end
      end
    rescue StandardError => e
      puts "ERROR: #{e.inspect}"
    end

    private

    attr_reader *READABLE_ATTRIBUTES

    def reset_instance_variables
      READABLE_ATTRIBUTES.each { |attr_reader_name| instance_variable_set("@#{attr_reader_name}", nil) }

      @aspect_group = nil
    end

    def original_photo_verbose_metadata
      @original_photo_verbose_metadata ||= begin
        identify_output = run_shell_command("magick identify -verbose #{base_photo_path}")
        metadata_lines  = identify_output.split("\n")

        # can't parse as YAML directly because it's weirdly fornatted with multiple levels and variable spacing
        # build a hash from the lines instead
        metadata_hash = metadata_lines.each_with_object({}) do |line, h|
          key, value = line.split(": ")
          key.gsub!(/\s{2,}/, '')
        
          h[key] = value
        end.compact

        @original_width, @original_height = begin
          metadata_hash["Geometry"].gsub(/\+0/, '').split("x").map(&:to_f)
        end

        metadata_hash
      end
    end

    def run_magick
      puts "creating #{version} version"
      @processed_photo_path = new_version_filepath
      puts "processed_photo_path: #{processed_photo_path}"

      resize_command = %W[
        magick
        #{base_photo_path}
        -resize
        #{resize_dimensions(version)}
        #{processed_photo_path}
      ].join(' ')

      run_shell_command(resize_command)

      puts "checking existance of: #{processed_photo_path}"
      
      if File.exist?(processed_photo_path)
        puts "successfully processed #{processed_photo_path}"
      else
        puts "ERROR: creating processed version '#{processed_photo_path}' failed, skipping upload to public bucket"
      end
    end

    def resize_dimensions(version)
      resize_width = RESIZE_VERSIONS[version]

      resize_percentage = ((resize_width / original_width) * 100).round(4)
      puts "resizing to: #{resize_percentage}%"
      "#{resize_percentage}%"
    end

    def new_version_filepath
      @base_filename, extension = base_filename_and_extension(
        filename_from_path(base_photo_path)
      )

      puts "base_filename: #{base_filename}"
      puts "'#{extension}' file detected"

      "#{TMP_IMAGE_BASE_PATH}/#{base_filename}-#{aspect_group}-#{version}#{extension}"
    end

    def filename_from_path(photo_path)
      photo_path.split('/').last
    end

    def aspect_group
      @aspect_group ||= begin
        puts "identifying image ratio for #{base_photo_path}..."

        puts "width: #{original_width}, height: #{original_height}"

        ratio = (original_width/original_height).round(2).to_s
        puts "ratio: #{ratio}\n"

        group = ASPECT_GROUP_MAPPINGS[ratio]

        puts "returning aspect group: #{group}"
        group
      end
    end

    def base_filename_and_extension(filename)
      extension = File.extname(filename)

      [File.basename(filename, extension), extension]
    end

    def run_shell_command(command_string)
      puts "running shell command: #{command_string}"

      `#{command_string} 2>&1`
    end

    def download_photo
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

    def upload_to_public_bucket
      return unless processed_photo_path

      destination_bucket_key = filename_from_path(processed_photo_path)
      puts "uploading '#{destination_bucket_key}' to public bucket"

      public_s3_bucket.object(destination_bucket_key).upload_file(processed_photo_path)

      if photo_uploaded?(destination_bucket_key, processed_photo_path)
        puts "finished upload of #{destination_bucket_key}, cleaning up tmp file"
      else
        raise StandardError, "ERROR: #{destination_bucket_key} not uploaded to public bucket"
      end
    ensure
      FileUtils.rm_f(processed_photo_path)
    end

    def invoke_webhook
      uri = URI(ENV["KEENEDREAMS_API_URL"])
      puts "invoking webhook with uri: #{uri}"
      post_request = Net::HTTP::Post.new(uri)

      post_request.set_form_data({
        keenedreams_api_client_key: ENV["KEENEDREAMS_API_KEY"],
        version: version,
        basename: base_filename,
        aspect_group: aspect_group,
        verbose_metadata: original_photo_verbose_metadata
      })

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
        http.request(post_request)
      end

      case response
      when Net::HTTPUnauthorized
        raise "ERROR: keenedreams did not authenticate request"
      when Net::HTTPCreated
        puts "POST to #{ENV['KEENEDREAMS_API_URL']} completed successfully"
      when Net::HTTPInternalServerError
        raise "ERROR: keenedreams returned a server error"
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

    def photo_uploaded?(bucket_key, file_path)
      object = public_s3_bucket.object(bucket_key)
      
      File.open(file_path, 'rb') do |file|
        object.put(body: file)
      end

      true
    rescue StandardError => e
      false
    end
  end
end
