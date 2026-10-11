require "test_helper"

class EventLogTest < ActiveSupport::TestCase
  def draw(log, player) = log.receive_event(Magic::Events::CardDraw.new(player: player))

  test "draws in a row by one player are one entry" do
    log = EventLog.new
    player = Magic::Player.new(name: "Player 2")

    draw(log, player)
    assert_equal ["Player 2 draws a card"], log.entries.map { _1[:text] }

    6.times { draw(log, player) }
    assert_equal ["Player 2 draws 7 cards"], log.entries.map { _1[:text] }
    assert_equal ["Player 2 draws 7 cards"], log.transcript.map { _1[:text] }
  end

  test "cards milled in a row by one player are one entry" do
    log = EventLog.new
    player = Magic::Player.new(name: "Player 1")

    %w[Forest Island Swamp].each do |name|
      card = Struct.new(:name).new(name)
      log.receive_event(Magic::Events::CardMilled.new(player: player, card: card))
    end

    assert_equal ["Player 1 mills Forest, Island, Swamp"], log.entries.map { _1[:text] }
  end

  test "the same permanent entering in a row under one controller is one entry" do
    log = EventLog.new
    player = Magic::Player.new(name: "Player 1")
    card = Struct.new(:land?).new(false)
    permanent = Struct.new(:name, :controller, :card, :tapped?).new("Elf Warrior", player, card, false)

    3.times { log.receive_event(Magic::Events::EnteredTheBattlefield.new(permanent, from: nil)) }

    assert_equal ["Elf Warrior enters the battlefield (Player 1) ×3"], log.entries.map { _1[:text] }
  end

  test "a permanent that enters tapped says so" do
    log = EventLog.new
    player = Magic::Player.new(name: "Player 1")
    card = Struct.new(:land?).new(false)
    permanent = Struct.new(:name, :controller, :card, :tapped?).new("Guildgate", player, card, true)

    log.receive_event(Magic::Events::EnteredTheBattlefield.new(permanent, from: nil))

    assert_equal ["Guildgate enters the battlefield tapped (Player 1)"], log.entries.map { _1[:text] }
  end

  test "a permanent entering under its controller's own spell doesn't name the controller" do
    log = EventLog.new
    player = Magic::Player.new(name: "Player 2")
    opponent = Magic::Player.new(name: "Player 1")
    card = Struct.new(:land?).new(false)
    item = Struct.new(:controller, :name).new(player, "Springbloom Druid")
    mine = Struct.new(:name, :controller, :card, :tapped?).new("Swamp", player, card, false)
    theirs = Struct.new(:name, :controller, :card, :tapped?).new("Elf Warrior", opponent, card, false)

    log.resolving(item) do
      log.receive_event(Magic::Events::EnteredTheBattlefield.new(mine, from: nil))
      log.receive_event(Magic::Events::EnteredTheBattlefield.new(theirs, from: nil))
    end

    assert_equal ["Swamp enters the battlefield", "Elf Warrior enters the battlefield (Player 1)"], log.entries.map { _1[:text] }
  end

  test "pumps and keywords given to several creatures by one cause are one line each" do
    log = EventLog.new
    source = Struct.new(:name).new("Elvish Warmaster")
    elves = ["Priest of Titania", "Elf Warrior", "Elf Warrior"].map { |name| Struct.new(:name).new(name) }

    elves.each do |elf|
      log.receive_event(Magic::Events::PowerToughnessModified.new(source: source, target: elf, power: 2, toughness: 2))
      log.receive_event(Magic::Events::KeywordGranted.new(source: source, target: elf, keyword: Magic::Cards::Keywords::DEATHTOUCH))
    end

    assert_equal ["Priest of Titania, Elf Warrior ×2 get +2/+2 until end of turn",
                  "Priest of Titania, Elf Warrior ×2 gain deathtouch"], log.entries.map { _1[:text] }
  end

  test "doubling effects are logged once each, and repeated skipped choices collapse into one line" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    p1 = game.players.first
    p2 = game.players.last
    game.current_turn.first_main! until game.current_turn.step.to_s.include?("main") || game.current_turn.number > 1
    [p1, p2].each { |player| player.hand.cards.to_a.each(&:move_to_graveyard!) }

    %w[AnointedProcession Panharmonicon WittyRoastmaster MentorOfTheMeek].each do |name|
      Magic::Permanent.resolve_spell(game: game, card: Magic::Cards.const_get(name).new(game: game, owner: p1))
    end
    target = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::CourserOfKruphix.new(game: game, owner: p2))
    spell = Magic::Cards::StolenByTheFae.new(game: game, owner: p1)
    p1.hand.add(spell)
    p1.add_mana(blue: 5)
    before = table.log.entries.size

    p1.cast(card: spell, value_for_x: 3) { |a| a.pay_mana(x: { blue: 3 }, blue: 2).targeting(target) }
    p1.mana_pool.transform_values! { 0 } # nothing left to pay for Mentor of the Meek
    table.send(:settle!)
    table.send(:dismiss_empty_choices!)

    shown = table.log.entries.drop(before)
    texts = shown.map { _1[:text] }
    assert_includes texts, "Anointed Procession doubles the tokens created (6)"
    assert_includes texts, "Panharmonicon: Witty Roastmaster triggers an additional time ×6"
    assert_includes texts, "Player 1 cast Stolen by the Fae targeting Courser of Kruphix"
    assert_includes texts, "Courser of Kruphix returns to Player 2's hand"
    assert_equal 1, texts.count { _1.start_with?("Player 1 could not pay for Mentor of the Meek") }

    # What the Faeries entering set off hangs from the Faeries, not from whatever was logged last.
    faeries = shown.find { _1[:text].start_with?("Faerie enters the battlefield") }
    effects = shown.select { _1[:text].start_with?("Witty Roastmaster deals 12 damage") || _1[:text].include?("could not pay") }
    assert_equal 2, effects.size
    assert(effects.all? { _1[:parent_id] == faeries[:id] })
  end

  test "identical attacks in a row are one line, and nothing is logged after a player has lost" do
    log = EventLog.new
    player = Magic::Player.new(name: "Player 1")
    attacker = Struct.new(:name).new("Elf Warrior")
    attack = Struct.new(:attacker, :target).new(attacker, player)

    2.times { log.receive_event(Magic::Events::AttackDeclared.new(active_player: player, turn: nil, attack: attack)) }
    log.receive_event(Magic::Events::PlayerLost.new(player: player))
    log.receive_event(Magic::Events::CardDraw.new(player: player))

    assert_equal ["Elf Warrior attacks Player 1 ×2", "Player 1 loses the game"], log.entries.map { _1[:text] }
  end

  test "a reveal announced twice is one line" do
    log = EventLog.new
    player = Magic::Player.new(name: "Player 1")
    card = Struct.new(:name).new("Forest")

    2.times { log.receive_event(Magic::Events::CardsRevealed.new(cards: [card], player: player)) }

    assert_equal ["Player 1 reveals Forest"], log.entries.map { _1[:text] }
  end

  test "a sacrifice and life paid as costs are logged under the spell or ability they were for" do
    log = EventLog.new
    player = Magic::Player.new(name: "Player 1")
    permanent = Struct.new(:name, :controller, :creature?, :token?).new("Treasure", player, false, true)
    spell = Struct.new(:name).new("Village Rites")

    log.receive_event(Magic::Events::PermanentSacrificed.new(permanent: permanent))
    log.receive_event(Magic::Events::SpellCast.new(spell: spell, player: player, mana_cost: nil))

    assert_equal ["Player 1 cast Village Rites", "Player 1 sacrificed Treasure"], log.entries.map { _1[:text] }
    assert_equal [0, 1], log.entries.map { _1[:depth] }
  end

  test "a painland's life loss is logged under the land that caused it" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    land = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::AdarkarWastes.new(game: game, owner: player))
    land.untap!

    player.activate_ability(ability: land.activated_abilities.last) { |a| a.choose(:blue) }

    loss = table.log.entries.find { _1[:text].include?("loses 1 life") }
    assert_equal "Adarkar Wastes (tapped for mana)", loss[:via]
    assert_match(/\(20 → 19\)\z/, loss[:text])
  end

  test "draws from several triggers of one cause add up even with other entries between them" do
    log = EventLog.new
    player = Magic::Player.new(name: "Player 1")
    source = Struct.new(:name).new("Mentor of the Meek")
    draw = ->(log) { log.receive_event(Magic::Events::CardDraw.new(player: player)) }

    log.receive_event(Magic::Events::DamageDealt.new(source: source, target: player, damage: 1))
    draw.call(log)
    log.receive_event(Magic::Events::DamageDealt.new(source: source, target: player, damage: 1))
    draw.call(log)

    assert_equal ["Mentor of the Meek deals 2 damage to Player 1", "Player 1 draws 2 cards"], log.entries.map { _1[:text] }
  end

  test "a planeswalker that loses its last loyalty is logged going to the graveyard" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    calix = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::CalixDestinysHand.new(game: game, owner: player))

    calix.change_loyalty!(-calix.loyalty)
    game.check_state_based_actions!

    assert_includes table.log.entries.map { _1[:text] }, "Calix, Destiny's Hand is put into #{player.name}'s graveyard"
  end

  test "a step is logged only once something happens in it" do
    log = EventLog.new
    player = Magic::Player.new(name: "Player 1")

    log.receive_event(Magic::Events::BeginningOfUpkeep.new(player: player))
    log.receive_event(Magic::Events::DrawStep.new(player: player))
    assert_empty log.entries

    log.receive_event(Magic::Events::CardDraw.new(player: player))

    assert_equal ["Draw step", "Player 1 draws a card"], log.entries.map { _1[:text] }
    assert_equal [:step, :draw], log.entries.map { _1[:kind] }
  end

  test "a sacrifice paid as a cost is logged under the ability it paid for" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    expanse = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::TerramorphicExpanse.new(game: game, owner: player))
    ability = expanse.activated_abilities.first
    log = EventLog.new

    log.receive_event(Magic::Events::PermanentSacrificed.new(permanent: expanse))
    log.receive_event(Magic::Events::AbilityActivated.new(ability: ability, player: player, targets: []))

    assert_equal ["#{player.name} activated Terramorphic Expanse", "#{player.name} sacrificed Terramorphic Expanse"],
                 log.entries.map { _1[:text] }
    assert_equal [0, 1], log.entries.map { _1[:depth] }
    assert_equal log.entries.first[:id], log.entries.last[:parent_id]
  end

  test "damage from one source to one target is one entry, without the life loss it caused" do
    log = EventLog.new
    source = Struct.new(:name).new("Impact Tremors")
    player = Magic::Player.new(name: "Player 2")

    3.times do
      log.receive_event(Magic::Events::LifeLoss.new(player: player, life: 1))
      log.receive_event(Magic::Events::DamageDealt.new(source: source, target: player, damage: 1))
    end

    assert_equal ["Impact Tremors deals 3 damage to Player 2"], log.entries.map { _1[:text] }
  end

  test "a different player or an entry in between starts a new draw entry" do
    log = EventLog.new
    one = Magic::Player.new(name: "Player 1")
    two = Magic::Player.new(name: "Player 2")

    draw(log, one)
    draw(log, two)
    draw(log, two)
    log.add(:info, "something happened")
    draw(log, two)

    assert_equal ["Player 1 draws a card", "Player 2 draws 2 cards", "something happened", "Player 2 draws a card"],
                 log.entries.map { _1[:text] }
  end
end
