# frozen_string_literal: true

require "net/http"
require "uri"

module Tus
  # Sends requests to TUS servers
  class Request
    attr_reader :server_uri, :http

    def initialize(url)
      @server_uri = URI.parse(url)

      @http =
        Net::HTTP.start(
          @server_uri.host,
          @server_uri.port,
          use_ssl: @server_uri.instance_of?(URI::HTTPS)
        )
      # @http.set_debug_output($stdout)
    end

    def options
      http.options(server_uri.request_uri)
    end

    def post(headers, retries)
      request = Net::HTTP::Post.new(server_uri.request_uri)
      headers.map { |header, value| request[header] = value }

      response =
        retries.times.find do
          break @http.request(request)
        rescue StandardError
          next
        end

      raise Error, "Cannot create a remote file!" unless response.is_a?(Net::HTTPCreated)

      validate_response_location(response)
    end

    def head(headers)
      raise Error, "location path is not set" unless @location_path

      request = Net::HTTP::Head.new(@location_path)
      headers.map { |header, value| request[header] = value }

      response = @http.request(request)

      raise Error, "Cannot fetch offset and length" unless response.is_a?(Net::HTTPOK)

      response
    end

    def patch(headers, retries, io)
      raise Error, "location path is not set" unless @location_path

      request = Net::HTTP::Patch.new(@location_path)
      headers.map { |header, value| request[header] = value }

      request.body_stream = io

      response =
        retries.times.find do
          break @http.request(request)
        rescue StandardError
          next
        end

      raise Error, "Cannot upload a chunk!" unless response.is_a?(Net::HTTPNoContent)

      response
    end

    private

    def validate_response_location(response)
      location_url = response["Location"]

      raise Error, "Malformed server response: missing 'Location' header" unless location_url

      @location_path = URI.parse(location_url).path
    end
  end
end
