# Copyright 2018 Twitch Interactive, Inc.  All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"). You may not
# use this file except in compliance with the License. A copy of the License is
# located at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# or in the "license" file accompanying this file. This file is distributed on
# an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
# express or implied. See the License for the specific language governing
# permissions and limitations under the License.

require_relative 'encoding'
require_relative 'error'
require_relative 'service_dsl'
require 'rack/request'

module Twirp

  class Service

    # DSL to define a service with package, service and rpcs.
    extend ServiceDSL

    class << self

      # Whether to raise exceptions instead of handling them with exception_raised hooks.
      # Useful during tests to easily debug and catch unexpected exceptions.
      attr_accessor :raise_exceptions # Default: false

      # Rack response with a Twirp::Error
      def error_response(twerr)
        status = Twirp::ERROR_CODES_TO_HTTP_STATUS[twerr.code]
        headers = {'content-type' => Encoding::JSON} # Twirp errors are always JSON, even if the request was protobuf
        resp_body = Encoding.encode_json(twerr.to_h)
        [status, headers, [resp_body]]
      rescue => err
        puts err
        puts err.backtrace.first(5).join("\n")
        exception_response(err)
      end

      def exception_response(e)
        twerr = Twirp::Error.internal_with(e)
        error_response(twerr)
      end
    end


    def initialize(handler)
      @handler = handler

      @before = []
      @on_success = []
      @on_error = []
      @exception_raised = []
    end

    # Setup hook blocks.
    def before(&block) @before << block; end
    def on_success(&block) @on_success << block; end
    def on_error(&block) @on_error << block; end
    def exception_raised(&block) @exception_raised << block; end

    # Service full_name is needed to route http requests to this service.
    def full_name; @full_name ||= self.class.service_full_name; end
    def name; @name ||= self.class.service_name; end

    # Rack app handler.
    def call(rack_env)
      env = {}
      bad_route = route_request(rack_env, env)
      return self.class.error_response(bad_route) if bad_route

      @before.each do |hook|
        result = hook.call(rack_env, env)
        return self.class.error_response(result) if result.is_a? Twirp::Error
      end

      headers = env[:http_response_headers].merge('content-type' => env[:content_type])
      stream = Stream.new(env) { |stream| call_handler(stream) }

      [200, headers, stream]
    rescue => e
      begin
        @exception_raised.each{|hook| hook.call(e, env) }
      rescue => hook_e
        e = hook_e
      end

      twerr = Twirp::Error.internal_with(e)
      self.class.error_response(twerr)
    end

  private

    # Parse request and fill env with rpc data.
    # Returns a bad_route error if could not be properly routed to a Twirp method.
    # Returns a malformed error if could not decode the body (either bad JSON or bad Protobuf)
    def route_request(rack_env, env)
      rack_request = Rack::Request.new(rack_env)

      if rack_request.request_method != "POST"
        return route_err(:bad_route, "HTTP request method must be POST", rack_request)
      end

      content_type = rack_request.get_header("CONTENT_TYPE")
      if !Encoding.valid_content_type?(content_type)
        return route_err(:bad_route, "Unexpected Content-Type: #{content_type.inspect}. Content-Type header must be one of #{Encoding.valid_content_types.inspect}", rack_request)
      end
      env[:content_type] = content_type

      path_parts = rack_request.path.split("/")
      if path_parts.size < 3 || path_parts[-2] != self.full_name
        return route_err(:bad_route, "Invalid route. Expected format: POST {BaseURL}/#{self.full_name}/{Method}", rack_request)
      end
      method_name = path_parts[-1]

      base_env = self.class.rpcs[method_name]
      if !base_env
        return route_err(:bad_route, "Invalid rpc method #{method_name.inspect}", rack_request)
      end
      env.merge!(base_env) # :rpc_method, :input_class, :output_class

      m = env[:ruby_method]
      if !@handler.respond_to?(m)
        return Twirp::Error.unimplemented("Handler method #{m} is not implemented.")
      end

      env[:http_response_headers] = {}
      return
    end

    def route_err(code, msg, req)
      Twirp::Error.new code, msg, twirp_invalid_route: "#{req.request_method} #{req.path}"
    end

    # Call handler method and return a Protobuf Message or a Twirp::Error.
    def call_handler(stream)
      @handler.send(stream.env[:ruby_method], stream)
    end
  end
end
