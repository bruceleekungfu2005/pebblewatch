module Pebble
  class Protocol
    module Errors
      class NotConnected < StandardError; end
      class LostConnection < StandardError; end
      class MalformedResponse < StandardError; end
    end

    attr_reader :connected
    attr_reader :message_handlers
    attr_reader :messages

    def self.open(port)
      protocol = new(port)

      begin
        protocol.connect
        yield protocol
      ensure
        protocol.disconnect
      end
      nil
    end

    def initialize(port)
      @port = port

      @connected          = false
      @send_message_mutex = Mutex.new
      @message_handlers   = Hash.new { |hash, key| hash[key] = [] }
      @messages = Queue.new
      @use_message_queue = false
    end

    def connect
      if @port.is_a?(String)
        require 'serialport'
        @serial_port = SerialPort.new(@port, baudrate: 115200)
      else
        @serial_port = @port
      end
      
      @connected = true
      Pebble.logger.debug "Connected to port #{@port}"
      
      @receive_messages_thread = Thread.new(&method(:receive_messages))

      true
    rescue LoadError
      puts "Please 'gem install hybridgroup-serialport' for serial port support."      
    end

    def disconnect
      raise Errors::NotConnected unless @connected

      @connected = false

      @serial_port.close()
      @serial_port = nil

      true
    end

    def listen_for_messages(sync=true)
      raise Errors::NotConnected unless @connected

      if sync
        @receive_messages_thread.join
      else
        @use_message_queue = true
        @receive_messages_thread.run
      end
    end

    def on_receive(endpoint = :any, &handler)
      @message_handlers[endpoint] << handler
      handler
    end

    def stop_receiving(*params)
      handler   = params.pop
      endpoint  = params.pop || :any

      @message_handlers[endpoint].delete(handler)
    end

    def send_message(endpoint, message, async_response_handler = nil, &response_parser)
      raise Errors::NotConnected unless @connected

      message ||= ""

      Pebble.logger.debug "Sending #{Endpoints.for_code(endpoint) || endpoint}: #{message.inspect}"

      data = [message.size, endpoint].pack("S>S>") + message

      @send_message_mutex.synchronize do
        @serial_port.write(data)

        if response_parser
          if async_response_handler
            identifier = on_receive(endpoint) do |response_message|
              stop_receiving(endpoint, identifier)

              parsed_response = response_parser.call(response_message)

              async_response_handler.call(parsed_response)
            end

            true
          else
            received        = false
            parsed_response = nil
            identifier = on_receive(endpoint) do |response_message|
              stop_receiving(endpoint, identifier)

              parsed_response = response_parser.call(response_message)
              received        = true
            end

            sleep 0.015 until received

            parsed_response
          end
        else
          true
        end
      end
    end

    private
      def receive_messages
        Pebble.logger.debug "Waiting for messages"
        while @connected
          header = @serial_port.read(4)
          next unless header

          raise Errors::MalformedResponse if header.length < 4

          size, endpoint = header.unpack("S>S>")
          next if endpoint == 0
          message = @serial_port.read(size)

          Pebble.logger.debug "Received #{Endpoints.for_code(endpoint) || endpoint}: #{message.inspect}"

          trigger_received(endpoint, message)
        end
      rescue IOError => e
        if @connected
          Pebble.logger.debug "Lost connection"
          @connected = false
          raise Errors::LostConnection
        end
      ensure
        Pebble.logger.debug "Finished waiting for messages"
      end

      def trigger_received(endpoint, message)
        @messages.push(event_for(endpoint, message)) if @use_message_queue

        @message_handlers[:any].each do |handler|
          Thread.new(handler) do |handler|
            handler.call(endpoint, message)
          end
        end

        @message_handlers[endpoint].each do |handler|
          Thread.new(handler) do |handler|
            handler.call(message)
          end
        end
      end

      def event_for(endpoint, message)
        events = {
          Pebble::Endpoints::LOGS => [:log, Pebble::Watch::LogEvent],
          Pebble::Endpoints::SYSTEM_MESSAGE => [:system_message, Pebble::Watch::SystemMessageEvent],
          Pebble::Endpoints::MUSIC_CONTROL => [:media_control, Pebble::Watch::MediaControlEvent],
          Pebble::Endpoints::APPLICATION_MESSAGE => [:app_message, Pebble::Watch::AppMessageEvent]
        }

        [events[endpoint][0], events[endpoint][1].parse(message)]
      end
  end
end