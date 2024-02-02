
module Twirp
  class Stream
    attr_reader :env

    def initialize(env, &block)
      @env = env
      @block = block
      @stream = nil
    end

    def read
      Encoding.decode(
        @stream.read,
        @env[:input_class],
        @env[:content_type],
      )
    end

    def write(out)
      result = case out
      when @env[:output_class], Twirp::Error
        out
      when Hash
        @env[:output_class].new(out)
      else
        Twirp::Error.internal("Handler method #{@env[:ruby_method]} expected to return one of #{@env[:output_class].name}, Hash or Twirp::Error, but returned #{out.class.name}.")
      end

      if result.is_a? Twirp::Error
        @stream.write(Service.error_response(result)[2])
      else
        resp_body = Encoding.encode(result, @env[:output_class], @env[:content_type])
        @stream.write(resp_body)
      end
    end

    def call(stream)
      @stream = stream
      out = @block.call(self)
      write(out) if out.is_a?(@env[:output_class]) || out.is_a?(Hash) || out.is_a?(Twirp::Error)
    rescue => e
      @stream.write(Service.exception_response(e))
    ensure
      @stream.close
      @stream = nil
    end
  end
end
