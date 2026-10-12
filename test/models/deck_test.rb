require "test_helper"

class DeckTest < ActiveSupport::TestCase
  test "every deck under config/decks is available, and none has a card the gem lacks" do
    assert_includes Deck.available, "enchantress"
    assert_includes Deck.available, "elves"
    assert_includes Deck.available, "jeskai"
    assert_includes Deck.available, "korvold"
    Deck.available.each do |name|
      assert_empty Deck.load(name).missing, "#{name} has cards that are not implemented"
    end
  end

  test "hyphenated and apostrophed names find their cards" do
    deck = Deck.new("x", "1 Dwynen, Gilt-Leaf Daen (DDU) 2\n1 Serpent's Soul-Jar (KHC) 11\n1 Bolas's Citadel (X) 1\n")

    assert_equal [Magic::Cards::DwynenGiltLeafDaen, Magic::Cards::SerpentsSoulJar, Magic::Cards::BolassCitadel], deck.entries.map(&:card_class)
  end

  test "a double-faced card listed with both faces finds the front face" do
    deck = Deck.new("x", "1 Needleverge Pathway / Pillarverge Pathway (ZNR) 288\n")

    assert_equal [Magic::Cards::NeedlevergePathway], deck.entries.map(&:card_class)
  end

  test "the registry gives a table the deck asked for, and the default for anything else" do
    assert_equal "elves", TableRegistry.fetch("deck-test-elves", deck: "elves").send(:view_for, "nobody")[:deck]
    assert_equal Table::DECK, TableRegistry.fetch("deck-test-unknown", deck: "../../etc/passwd").send(:view_for, "nobody")[:deck]
    assert_equal Table::DECK, TableRegistry.fetch("deck-test-none").send(:view_for, "nobody")[:deck]
  end

  test "the choices are the five decks, each led by its commander" do
    commanders = Deck::CHOICES.to_h { |name| [name, Deck.load(name).commander] }

    assert_equal(
      { "enchantress" => "Anikthea, Hand of Erebos", "elves" => "Lathril, Blade of the Elves",
        "jeskai" => "Zinnia, Valley's Voice", "korvold" => "Korvold, Fae-Cursed King",
        "endless_punishment" => "Valgavoth, Harrower of Souls" },
      commanders
    )
    assert_equal commanders.map { |name, commander| { name: name, commander: commander } },
                 Table.new("choices").view_for("nobody")[:decks]
  end

  test "each player plays the deck they picked when joining" do
    table = Table.new("pick-decks")
    table.join("a", "elves")
    table.join("b", "korvold")

    assert_equal "elves", table.view_for("a")[:deck]
    assert_equal "korvold", table.view_for("b")[:deck]
    commanders = table.seats.map { |seat| seat.player.commander.name }
    assert_equal ["Lathril, Blade of the Elves", "Korvold, Fae-Cursed King"], commanders
  end

  test "a player who picks nothing, or something that is not a choice, gets the table's deck" do
    table = Table.new("pick-default")
    table.join("a", "scute_swarm")
    table.join("b")

    assert_equal [Table::DECK, Table::DECK], table.seats.map { |seat| seat.deck.name }
  end
end
