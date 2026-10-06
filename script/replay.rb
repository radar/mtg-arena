# Replays a saved game record (tmp/games/*.json, written when a game ends) and stops at the first call that goes differently.
# Usage: bin/rails runner script/replay.rb tmp/games/<file>.json [calls to replay]
#
# Prints each call and Table's answer, then the divergence (if any), the errors the original game hit, and the end of
# the game log. Paste the record's path (or its "errors" and the tail of its "log") into a prompt to have a bug fixed.
require "json"

path = ARGV.fetch(0) { abort "usage: bin/rails runner script/replay.rb <record.json> [calls]" }
record = JSON.parse(File.read(path))
puts "table #{record['table_id']}  seed #{record['seed']}  deck #{record['deck']}  #{record['calls'].size} calls  saved because: #{record['reason']}"

replay = Table::Replay.new(record)
replay.run(through: ARGV[1]&.to_i) do |index, call, result|
  puts "#{index}: #{call['method']} #{call['args'].to_json}#{" => #{result}" if result}"
end

if replay.divergence
  divergence = replay.divergence
  puts "DIVERGED at call #{divergence[:index]} (#{divergence[:reason]}): expected #{divergence[:expected].inspect}, got #{divergence[:got].inspect}"
  exit 1
end

Array(record["errors"]).each do |error|
  puts "ERROR at call #{error['call']}: #{error['class']}: #{error['message']}"
  puts error["backtrace"].first(5).map { |line| "  #{line}" }
end
puts "replayed as recorded. Winner: #{record['winner'] || 'none'}"
