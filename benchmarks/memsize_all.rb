# frozen_string_literal: true

# Measure retained heap size after loading rubycog and triggering GC.
# Lower is better.
#
# ObjectSpace.memsize_of_all sums every live object's bytes — a coarse but
# useful proxy for "did this change make us hold more stuff in memory".

require 'objspace'
require_relative '../lib/rubycog'

GC.start
GC.start
bytes = ObjectSpace.memsize_of_all

puts "memsize_all\t#{bytes}"
