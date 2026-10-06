require "test_helper"
require "tmpdir"

class TableReplayTest < ActiveSupport::TestCase
  def bot_game(seed, deck_name = "enchantress")
    table = Table.new("replay-#{seed}", deck: Deck.load(deck_name), seed: seed)
    table.join("p1")
    table.join("p2")
    Bot.new(table).play
    table
  end

  test "a finished game replays call for call from its record" do
    table = bot_game(1)
    record = JSON.parse(JSON.generate(table.game_record(reason: "game over")))

    replay = Table::Replay.new(record)

    assert replay.run, "diverged: #{replay.divergence.inspect}"
    assert_equal table.winner_name, replay.table.winner_name
    assert_equal table.state_summary, replay.table.state_summary
  end

  test "a record that does not match the seed diverges instead of replaying quietly" do
    record = JSON.parse(JSON.generate(bot_game(1).game_record(reason: "game over")))
    record["seed"] += 1

    replay = Table::Replay.new(record)

    assert_not replay.run
    assert replay.divergence
  end

  test "ids in a record are positions, not object ids" do
    table = bot_game(1)
    encoded = table.calls.flat_map { |call| call["args"] }.flatten.grep(String)

    assert encoded.any? { |arg| arg.start_with?(Table::Recording::REF) }
  end

  test "a game that ends is written to the record directory" do
    Dir.mktmpdir do |directory|
      ENV["GAME_RECORD_DIR"] = directory
      table = Table.new("saved", deck: Deck.load("enchantress"), seed: 2)
      table.join("p1")
      table.join("p2")
      assert_empty Dir[File.join(directory, "*.json")]

      table.concede("p1")

      files = Dir[File.join(directory, "*.json")]
      assert_equal 1, files.size
      record = JSON.parse(File.read(files.first))
      assert_equal 2, record["seed"]
      assert_equal "Player 2", record["winner"]
      assert_equal %w[join join concede], record["calls"].map { |call| call["method"] }
    ensure
      ENV.delete("GAME_RECORD_DIR")
    end
  end

  test "the shuffle depends on the seed alone" do
    first = Table.new("a", deck: Deck.load("enchantress"), seed: 7).tap { |t| t.join("p1"); t.join("p2") }
    srand(123)
    second = Table.new("b", deck: Deck.load("enchantress"), seed: 7).tap { |t| t.join("p1"); t.join("p2") }

    assert_equal first.state_summary, second.state_summary
  end
end
