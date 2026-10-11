# Compares what each implemented deck card says about itself (name, mana cost, power/toughness, loyalty) with its Oracle
# entry. Prints one line per mismatch. Run with `bin/rails runner script/audit_stats.rb`; DECK=elves picks another deck.
require "json"

oracle = {}
File.foreach(Rails.root.join("../mtg/data/oracle-cards-20260908210154.jsonl")) do |line|
  card = JSON.parse(line)
  oracle[card["name"]] ||= card
end

Deck.load(ENV.fetch("DECK", Table::DECK)).entries.each do |entry|
  next unless entry.card_class

  expected = oracle[entry.name]
  unless expected
    puts "#{entry.name}: not in oracle data"
    next
  end

  # A game of its own for each card: other permanents (an elf lord) would change its power and toughness.
  table = Table.new("audit", deck: Deck.new("x", "40 Forest (X) 1\n"))
  table.join("a")
  table.join("b")
  game = table.game
  player = game.current_turn.active_player

  card = entry.card_class.new(game: game, owner: player)
  problems = []
  problems << "name #{card.name.inspect}, oracle #{expected['name'].inspect}" if card.name != expected["name"]
  # {X} counts as 0 in the Oracle's mana value, and as 1 in the engine's cost.
  has_x = expected["mana_cost"].to_s.include?("{X}")
  problems << "mana value #{card.mana_value}, oracle #{expected['cmc'].to_i}" if card.mana_value != expected["cmc"].to_i && !has_x
  # Colours in the cost: {1}{G}{G} is { generic: 1, green: 2 }.
  letters = { "W" => :white, "U" => :blue, "B" => :black, "R" => :red, "G" => :green, "X" => :x }
  oracle_cost = expected["mana_cost"].to_s.scan(/\{(\w+)\}/).flatten.each_with_object(Hash.new(0)) do |symbol, cost|
    symbol.match?(/\A\d+\z/) ? cost[:generic] += symbol.to_i : cost[letters.fetch(symbol, symbol)] += 1
  end
  actual_cost = card.cost.cost.to_h.reject { |_, amount| amount.to_i.zero? }
  problems << "cost #{actual_cost}, oracle #{oracle_cost.reject { |_, n| n.zero? }}" if !card.land? && actual_cost != oracle_cost.reject { |_, n| n.zero? }
  if expected["power"] || expected["loyalty"]
    # Power, toughness and loyalty belong to the permanent.
    card = Magic::Permanent.resolve_spell(game: game, card: card)
  end
  # A "*" in the Oracle power or toughness is defined by the card's own text (Daxos), so it can't be compared.
  if expected["power"] && !(expected["power"] + expected["toughness"]).include?("*")
    actual = [card.power, card.toughness].map(&:to_s)
    problems << "P/T #{actual.join('/')}, oracle #{expected['power']}/#{expected['toughness']}" if actual != [expected["power"], expected["toughness"]]
  end
  problems << "loyalty #{card.loyalty}, oracle #{expected['loyalty']}" if expected["loyalty"] && card.loyalty.to_s != expected["loyalty"]
  puts "#{entry.name}: #{problems.join('; ')}" if problems.any?
end
