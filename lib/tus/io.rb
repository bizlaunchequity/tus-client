module Tus
  class IO
    def initialize(io, file_size, &block)
      @io = io
      @file_size = file_size
      @offset = 0
      @block = block
    end

    def read(*)
      @block.call(@offset, @file_size) if @block
      chunk = @io.read(*)
      @offset += chunk.length if chunk
      chunk
    end

    def method_missing(*)
      @io.send(*)
    end
  end
end
