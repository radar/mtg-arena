module TableRegistry
  MUTEX = Mutex.new
  TABLES = {}

  # The table for game +id+, created on first use with +deck+ (a name from Deck.available; anything else, or none, gets
  # the default). Both players share the table's deck, so whoever opens the game first chooses it.
  def self.fetch(id, deck: nil)
    MUTEX.synchronize do
      TABLES[id] ||= Table.new(id, deck: Deck.load(Deck.available?(deck) ? deck : Table::DECK))
    end
  end
end
