# Plays a game record (see Table::Recording) back through a fresh Table with the same seed, call by call, and stops at the
# first call that does not come out as it did: a different answer from Table, a different game state, or an exception.
#
#   replay = Table::Replay.new(JSON.parse(File.read(path)))
#   replay.run { |index, call, result| puts "#{index} #{call['method']} #{result.inspect}" }
#   replay.divergence # => nil, or { index:, call:, expected:, got:, ... }
class Table
  class Replay
    attr_reader :record, :table, :divergence

    def initialize(record)
      @record = record
      @table = Table.new(record["table_id"], deck: Deck.load(record["deck"]), seed: record["seed"], save_records: false)
      @divergence = nil
    end

    # Replays up to +through+ calls (all by default). Yields each call's index, the recorded call and Table's answer.
    # Returns true when every call came out as recorded.
    def run(through: nil)
      calls = record["calls"]
      calls = calls.first(through) if through
      calls.each_with_index do |call, index|
        method = call["method"]
        result = begin
          table.public_send(method, *table.decode_arguments(method.to_sym, call["args"]))
        rescue StandardError => e
          "raised #{e.class}: #{e.message}"
        end
        result = Recording.result_for_record(result)
        yield index, call, result if block_given?

        digest = table.calls.last&.fetch("digest")
        if result != call["result"]
          @divergence = { index: index, call: call, reason: "answer differs", expected: call["result"], got: result }
        elsif digest != call["digest"]
          @divergence = { index: index, call: call, reason: "game state differs", expected: call["digest"], got: digest }
        end
        return false if @divergence
      end
      true
    end
  end
end
