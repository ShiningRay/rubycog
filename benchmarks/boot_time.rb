# frozen_string_literal: true

# Measure wall-clock time to require rubycog. Lower is better.

require 'benchmark'

elapsed = Benchmark.realtime do
  require_relative '../lib/rubycog'
end

puts format("boot_time\t%.6f", elapsed)
