# frozen_string_literal: true

# require "net/http"
require "base64"
# require "uri"

require_relative "client/version"
require_relative "error"
require_relative "request"

module Tus
  # Uploads files to TUS servers
  class Client
    CHUNK_SIZE = 50 * 1024 * 1024
    TUS_VERSION = "1.0.0"
    NUM_RETRIES = 5

    def initialize(url, chunk_size: CHUNK_SIZE, retries: NUM_RETRIES, metadata: {}, headers: {})
      @request = Request.new(url)

      retries(retries)
      chunk_size(chunk_size)
      metadata(metadata)
      headers(headers)

      @capabilities = capabilities
    end

    def retries(retries)
      raise Error, "is not a valid retries" unless retries.instance_of?(Integer) && retries.positive?

      @retries = retries

      self
    end

    def chunk_size(size)
      raise Error, "is not a valid chunk size" unless size.instance_of?(Integer) && size.positive?

      @chunk_size = size

      self
    end

    def metadata(metadata)
      raise Error, "is not a valid metadata" unless metadata.instance_of?(Hash)

      metadata = metadata.map do |key, value|
        if value
          "#{key} #{Base64.strict_encode64(value)}"
        else
          key.to_s
        end
      end

      @metadata = metadata.join(",")

      self
    end

    def headers(headers)
      raise Error, "is not valid headers" unless headers.instance_of?(Hash)

      @headers = headers

      self
    end

    def upload_by_path(file_path, &)
      raise Error, "no such file" unless File.file?(file_path)

      file_size = File.size(file_path)
      io = File.open(file_path, "rb")

      upload_by_io(file_size:, io:, &)
    end

    def upload_by_link(url, &)
      uri = URI.parse(url)

      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.instance_of?(URI::HTTPS)) do |http|
        file_size = fetch_file_size(uri, http)
        puts "file size is #{file_size}"

        req = Net::HTTP::Get.new(uri)
        http.request(req) do |res|
          create_remote(file_size)
          current_offset, length = fetch_upload_state
          puts "current offset: #{current_offset}"
          puts "total bytes: #{length}"
          acc = ""

          res.read_body do |chunk|
            acc += chunk
            current_offset = try_upload_chunk(current_offset, length, acc, &)
          end

          upload_chunk(current_offset, length, acc, &) if acc.length.positive?
        end
      end
    end

    def upload_by_io(file_size:, io:, &block)
      raise Error, "Cannot upload a stream of unknown size!" unless file_size

      create_remote(file_size)
      current_offset, length = fetch_upload_state

      loop do
        chunk = io.read(@chunk_size)
        break unless chunk

        current_offset =
          begin
            upload_chunk(current_offset, length, chunk, &block)
          rescue StandardError
            raise Error, "Broken upload! Cannot send a chunk!"
          end
      end

      raise Error, "Broken upload!" unless current_offset == length
    ensure
      io.close
    end

    private

    def fetch_file_size(uri, http)
      response = http.head(uri.request_uri)
      file_size = response["Content-Length"].to_i
      raise Error, "Cannot upload a stream of unknown size!" unless file_size.positive?

      file_size
    end

    def try_upload_chunk(current_offset, length, acc, &)
      if acc.length >= @chunk_size
        puts "current chunk size #{acc.length}"
        ch = acc.slice!(0, @chunk_size)
        current_offset = upload_chunk(current_offset, length, ch, &)

        try_upload_chunk(current_offset, length, acc)
      else
        current_offset
      end
    end

    def capabilities
      response = @request.options

      response["Tus-Extension"]&.split(",")
    end

    def create_remote(file_size)
      raise Error, "New file uploading is not supported!" unless @capabilities.include?("creation")

      headers = @headers.dup
      headers["Content-Length"] = 0
      headers["Upload-Length"] = file_size
      headers["Tus-Resumable"] = TUS_VERSION
      headers["Upload-Metadata"] = @metadata

      @request.post(headers, @retries)
    end

    def fetch_upload_state
      headers = @headers.dup
      headers["Tus-Resumable"] = TUS_VERSION
      response = @request.head(headers)

      [response["Upload-Offset"], response["Upload-Length"]].map(&:to_i)
    end

    def upload_chunk(offset, length, chunk)
      puts "upload chank: offset: #{offset}, total bytes: #{length}, chunk length: #{chunk.length}"
      headers = @headers.dup
      headers["Content-Type"] = "application/offset+octet-stream"
      headers["Upload-Offset"] = offset
      headers["Tus-Resumable"] = TUS_VERSION

      response = @request.patch(headers, @retries, chunk)

      resulting_offset = response["Upload-Offset"].to_i
      raise "Chunk upload is broken!" unless resulting_offset == offset + chunk.size

      yield resulting_offset, length if block_given?

      resulting_offset
    end
  end
end
