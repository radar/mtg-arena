# A decklist file under config/decks, in the common "1 Card Name (SET) 123" text format.
# Cards the mtg gem has not implemented yet are skipped and reported by #missing.
class Deck
  Entry = Struct.new(:count, :name, :card_class)

  # The decks a player can pick when joining a game; each deck's first card is its commander.
  CHOICES = %w[enchantress elves jeskai korvold endless_punishment].freeze

  attr_reader :name, :entries

  def self.load(name)
    new(name, Rails.root.join("config/decks/#{name}.txt").read)
  end

  # The decks a game can be played with: one file per deck under config/decks.
  def self.available
    Dir[Rails.root.join("config/decks/*.txt")].map { |path| File.basename(path, ".txt") }.sort
  end

  def self.available?(name)
    available.include?(name.to_s)
  end

  def initialize(name, text)
    @name = name
    @entries = text.lines.filter_map do |line|
      match = line.match(/\A(\d+)\s+(.+?)\s+\(/)
      next unless match

      Entry.new(match[1].to_i, match[2], card_class_for(match[2]))
    end
  end

  def commander
    entries.first.name
  end

  def missing
    entries.reject(&:card_class).map(&:name)
  end

  # One class per physical card, e.g. five Forests are five Forest classes.
  def card_classes
    entries.select(&:card_class).flat_map { |entry| [entry.card_class] * entry.count }
  end

  def self.card_class_for(card_name)
    # A hyphen separates words ("Gilt-Leaf" is GiltLeaf); an apostrophe just disappears ("Serpent's" is Serpents).
    # A double-faced card is listed with both faces ("Needleverge Pathway / Pillarverge Pathway"): the front is the class.
    # A Room is one class named for both doors ("Spiked Corridor / Torture Pit" is SpikedCorridorTorturePit), so try that first.
    [card_name, card_name.split(" / ").first].each do |candidate|
      const = candidate.tr("-/", "  ").gsub(/[^a-z\s]/i, "").split.map(&:capitalize).join
      return Magic::Cards.const_get(const) if Magic::Cards.const_defined?(const)
    end
    nil
  end

  private

  def card_class_for(card_name) = self.class.card_class_for(card_name)
end
