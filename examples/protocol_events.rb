require "pebble"

watch = Pebble::Watch.new("378B", "/dev/rfcomm0")
#Pebble.logger.level = Logger::DEBUG

# watch.protocol.on_receive do |message|
#   puts message
# end

watch.on_event(:media_control) do |event|
  case event.button
  when :playpause
    puts "Play or pause music"
  when :next
    puts "Next track"
  when :previous
    puts "Previous track"
  end
end

watch.connect

watch.listen_for_events
