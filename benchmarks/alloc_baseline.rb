# frozen_string_literal: true

# Measure baseline object allocations when loading the rubycog library.
# Lower is better. Sidecar file alloc_baseline.rb.direction sets this.
#
# Run with the project root as chdir. The BenchmarkRunner runs this in both
# main and a worktree so we can see whether a refactor changed allocation
# pressure at boot.

require 'objspace'

before = GC.stat(:total_allocated_objects)
require_relative '../lib/rubycog'
after = GC.stat(:total_allocated_objects)

puts "alloc_baseline\t#{after - before}"
