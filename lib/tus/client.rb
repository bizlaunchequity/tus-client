# frozen_string_literal: true

# require "net/http"
require "base64"
# require "uri"

require_relative "client/version"
require_relative "io"
require_relative "error"
require_relative "request"

module Tus
  # Uploads files to TUS servers
  class Client
    CHUNK_SIZE = 50 * 1024 * 1024
    TUS_VERSION = "1.0.0"
    NUM_RETRIES = 5

    def initialize(url, retries: NUM_RETRIES, metadata: {}, headers: {})
      @request = Request.new(url)
      @stats = []

      retries(retries)
      metadata(metadata)
      headers(headers)

      @capabilities = capabilities
    end

    def retries(retries)
      raise Error, "is not a valid retries" unless retries.instance_of?(Integer) && retries.positive?

      @retries = retries

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
      io = IO.new(io, file_size, &)

      upload_by_io(file_size:, io:)
    end

    def upload_by_link(url, &block)
      uri = URI.parse(url)

      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.instance_of?(URI::HTTPS)) do |http|
        file_size = fetch_file_size(uri, http)
        read_io, write_io = ::IO.pipe
        write_io.binmode
        read_io.binmode
        rd_io = Tus::IO.new(read_io, file_size, &block)

        req = Net::HTTP::Get.new(uri)
        http.request(req) do |res|
          Thread.new do
            res.read_body(write_io)
          ensure
            write_io.close
            Thread.current.exit
          end

          upload_by_io(file_size:, io: rd_io)
        end
      end
    end

    def upload_by_io(file_size:, io:)
      raise Error, "Cannot upload a stream of unknown size!" unless file_size

      create_remote(file_size)
      current_offset, length = fetch_upload_state

      current_offset =
        begin
          upload(current_offset, length, io)
        rescue StandardError
          raise Error, "Broken upload!"
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

    def upload(offset, length, io)
      headers = @headers.dup
      headers["Content-Type"] = "application/offset+octet-stream"
      headers["Upload-Offset"] = offset
      headers["Tus-Resumable"] = TUS_VERSION
      headers["Content-Length"] = length

      response = @request.patch(headers, @retries, io)

      resulting_offset = response["Upload-Offset"].to_i
      raise "Chunk upload is broken!" unless resulting_offset == length

      resulting_offset
    end
  end
end
