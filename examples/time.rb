require "pebble"

watch = Pebble::Watch.new("378B", "/dev/rfcomm0")
#Pebble.logger.level = Logger::DEBUG

watch.connect
puts watch.get_time
watch.disconnect
