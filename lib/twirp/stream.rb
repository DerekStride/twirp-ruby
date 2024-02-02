
module Twirp
  class Stream
    def initialize(env, &block)
      @env = env
      @block = block
    end

    def call(stream)
      input = Encoding.decode(stream.read, @env[:input_class], @env[:content_type])

      result = @block.call(input)

      if result.is_a? Twirp::Error
        stream.write(Service.error_response(result)[2])
      else
        resp_body = Encoding.encode(result, @env[:output_class], @env[:content_type])
        stream.write(resp_body)
      end
    ensure
      stream.close
    end
  end
end
