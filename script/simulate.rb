# Plays a whole game of the default deck with a Bot standing in for both players.
# Usage: bin/rails runner script/simulate.rb [seed] [max_decisions]
seed = (ARGV[0] || rand(10_000)).to_i
srand(seed)
puts "seed #{seed}"

# DECK=elves bin/rails runner script/simulate.rb 5 plays the other deck.
table = Table.new("sim", deck: Deck.load(ENV.fetch("DECK", Table::DECK)), seed: seed)
table.join("p1")
table.join("p2")

begin
  bot = Bot.new(table, max_decisions: (ARGV[1] || 3000).to_i, log: ->(message) { puts message }).play
rescue Bot::Stuck => e
  puts "BUG: #{e.message}"
  exit 1
end

view = table.view_for("p1")
puts "GAME OVER after #{bot.decisions} decisions. Winner: #{view[:winner] || 'draw'}. Life #{view[:you][:life]} / #{view[:opponent][:life]}"
