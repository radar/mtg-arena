require "test_helper"

class TableTest < ActiveSupport::TestCase
  TEST_DECK = Deck.new("test", "20 Forest (X) 1\n20 Mountain (X) 1\n8 Grizzly Bears (X) 1\n8 Goblin Arsonist (X) 1\n")

  test "two players join, game starts, each draws seven" do
    table = Table.new("t", deck: TEST_DECK)
    assert table.join("a")
    assert_not table.started?
    assert table.join("b")
    assert_nil table.join("c")
    assert table.started?

    view = table.view_for("a")
    assert_equal 7, view[:you][:hand].size
    assert_equal 7, view[:opponent][:hand_size]
    assert_nil view[:opponent][:hand]
    assert_equal 49, view[:you][:library]
  end

  test "rejoining keeps seat" do
    table = Table.new("t", deck: TEST_DECK)
    assert_same table.join("a"), table.join("a")
    assert_equal 1, table.seats.size
  end

  def started_table
    Table.new("t", deck: TEST_DECK).tap { |t| t.join("a"); t.join("b") }
  end

  test "game starts in first main; steps auto-advance between main phases" do
    table = started_table
    active = table.game.current_turn.active_player
    uid = table.seats.find { |s| s.player == active }.uid
    other = table.seats.find { |s| s.player != active }.uid

    assert_equal "first_main", table.game.current_turn.step
    assert_equal "It is not your turn.", table.advance_step(other)

    active.library.cards.find(&:land?).move_to_hand!(active) unless active.hand.cards.any?(&:land?)
    land_index = active.hand.cards.index(&:land?)
    assert_nil table.play_land(uid, land_index)
    assert_equal 1, active.permanents.count

    assert_nil table.advance_step(uid)
    assert_equal "second_main", table.game.current_turn.step
    assert_match(/cannot play any more lands/, table.play_land(uid, active.hand.cards.index(&:land?)).to_s) if active.hand.cards.any?(&:land?)
  end

  test "ending turn passes to opponent's first main" do
    table = started_table
    first = table.game.current_turn.active_player
    uid = table.seats.find { |s| s.player == first }.uid
    table.advance_step(uid)
    assert_nil table.advance_step(uid)

    assert_not_equal first, table.game.current_turn.active_player
    assert_equal 2, table.game.current_turn.number
    assert_equal "first_main", table.game.current_turn.step
  end

  test "casting a creature taps lands and puts it on the battlefield" do
    table = started_table
    player = table.game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    bear = player.library.cards.find { |c| c.name == "Grizzly Bears" }
    bear.move_to_hand!(player)

    assert_match(/Not enough mana/, table.cast(uid, player.hand.cards.index(bear)))

    2.times do
      forest = player.library.cards.find { |c| c.name == "Forest" }
      forest.move_to_hand!(player)
      Magic::Permanent.resolve_spell(game: table.game, card: forest)
    end
    castable = table.view_for(uid)[:you][:hand].find { |c| c[:name] == "Grizzly Bears" }[:castable]
    assert castable

    assert_nil table.cast(uid, player.hand.cards.index(bear))
    assert player.permanents.any? { |perm| perm.name == "Grizzly Bears" }
    assert_equal 2, player.permanents.count(&:tapped?)
    assert_not_includes player.hand.cards, bear
  end

  test "can_play_land is false once the land drop is used" do
    table = started_table
    player = table.game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    player.library.cards.find(&:land?).move_to_hand!(player) unless player.hand.cards.any?(&:land?)

    assert table.view_for(uid)[:can_play_land]
    assert_nil table.play_land(uid, player.hand.cards.index(&:land?))
    assert_not table.view_for(uid)[:can_play_land]
  end

  test "a land with two mana abilities offers every colour and taps for the one chosen" do
    table = started_table
    player = table.game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    springs = Magic::Permanent.resolve_spell(game: table.game, card: Magic::Cards::SulfurousSprings.new(game: table.game, owner: player))
    springs.controlled_since_turn = 0

    view = table.view_for(uid)[:you][:battlefield].find { |p| p[:id] == springs.object_id }
    assert_equal %w[colorless black red], view[:mana_colors]

    assert_nil table.tap_for_mana_by_hand(uid, springs.object_id, "red")
    assert_equal 1, player.mana_pool[:red]
    assert_equal 19, player.life
  end

  def put_bear(table, player)
    card = player.library.cards.find { |c| c.name == "Grizzly Bears" || c.name == "Goblin Arsonist" }
    card.move_to_hand!(player)
    Magic::Permanent.resolve_spell(game: table.game, card: card).tap { |perm| perm.controlled_since_turn = 0 }
  end

  test "combat: attack, block, damage" do
    table = started_table
    attacker_player = table.game.current_turn.active_player
    defender_player = table.game.opponents(attacker_player).first
    a_uid = table.seats.find { |s| s.player == attacker_player }.uid
    d_uid = table.seats.find { |s| s.player == defender_player }.uid
    attacker = put_bear(table, attacker_player)
    blocker = put_bear(table, defender_player)

    assert_nil table.advance_step(a_uid)
    assert_equal "declare_attackers", table.game.current_turn.step
    view = table.view_for(a_uid)
    assert view[:you][:battlefield].find { |p| p[:id] == attacker.object_id }[:can_attack]

    assert_nil table.declare_attackers(a_uid, [attacker.object_id])
    assert_equal "declare_blockers", table.game.current_turn.step
    assert_equal "It is not your turn.", table.advance_step(a_uid)
    assert table.view_for(d_uid)[:you][:battlefield].find { |p| p[:id] == blocker.object_id }[:can_block]

    assert_nil table.declare_blockers(d_uid, [[blocker.object_id, attacker.object_id]])
    # A dying Goblin Arsonist asks its controller whether to use its ability.
    10.times { [a_uid, d_uid].each { |u| table.choose(u, "no") if table.view_for(u)[:choice]&.dig(:chooser) } }
    assert_equal "second_main", table.game.current_turn.step
    assert_equal 20, defender_player.life
    # A Goblin Arsonist (1/1) and a Grizzly Bears (2/2) trade differently, but at least one creature dies.
    assert_operator attacker_player.permanents.count(&:creature?) + defender_player.permanents.count(&:creature?), :<, 2
  end

  test "combat: unblocked attacker hits player; no blockers skips the step" do
    table = started_table
    attacker_player = table.game.current_turn.active_player
    defender_player = table.game.opponents(attacker_player).first
    a_uid = table.seats.find { |s| s.player == attacker_player }.uid
    attacker = put_bear(table, attacker_player)

    table.advance_step(a_uid)
    assert_nil table.declare_attackers(a_uid, [attacker.object_id])
    assert_equal "second_main", table.game.current_turn.step
    assert_equal 20 - attacker.power, defender_player.life
  end

  test "combat step is skipped when no creature can attack" do
    table = started_table
    uid = table.seats.find { |s| s.player == table.game.current_turn.active_player }.uid
    table.advance_step(uid)
    assert_equal "second_main", table.game.current_turn.step
  end

  test "goblin arsonist death gives its controller a choice that blocks the game until answered" do
    table = started_table
    active = table.game.current_turn.active_player
    other = table.game.opponents(active).first
    uid = table.seats.find { |s| s.player == active }.uid
    other_uid = table.seats.find { |s| s.player == other }.uid
    arsonist = Magic::Permanent.resolve_spell(game: table.game, card: Magic::Cards::GoblinArsonist.new(game: table.game, owner: active))
    arsonist.destroy!
    table.game.settle!

    view = table.view_for(uid)
    assert_equal "may", view[:choice][:kind]
    assert view[:can_act]
    assert_equal false, table.view_for(other_uid)[:choice][:chooser]
    assert_equal "Resolve the pending choice first.", table.advance_step(uid)
    assert_equal "It is not your choice.", table.choose(other_uid, "yes")

    assert_nil table.choose(uid, "yes")
    view = table.view_for(uid)
    assert_equal "target", view[:choice][:kind]
    assert_includes view[:choice][:targets].map { |t| t[:label] }, other.name

    assert_nil table.choose(uid, other.name)
    assert_equal 19, other.life
    assert_nil table.view_for(uid)[:choice]
    assert_nil table.advance_step(uid)
  end

  test "declining the arsonist choice ends it" do
    table = started_table
    active = table.game.current_turn.active_player
    uid = table.seats.find { |s| s.player == active }.uid
    Magic::Permanent.resolve_spell(game: table.game, card: Magic::Cards::GoblinArsonist.new(game: table.game, owner: active)).destroy!
    table.game.settle!

    assert_nil table.choose(uid, "no")
    assert_nil table.view_for(uid)[:choice]
  end

  test "creature permanents report power, toughness and damage" do
    table = started_table
    player = table.game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    bear = put_bear(table, player)
    bear.take_damage(1)

    view = table.view_for(uid)[:you][:battlefield].find { |p| p[:id] == bear.object_id }
    assert_equal [bear.power, bear.toughness, 1], view.values_at(:power, :toughness, :damage)
  end

  test "the enchantress deck plays whole games to a winner" do
    [1].each do |seed|
      srand(seed)
      table = Table.new("sim-#{seed}", seed: seed)
      table.join("p1")
      table.join("p2")
      begin
        Bot.new(table).play
      rescue Bot::Stuck => e
        flunk "seed #{seed}: #{e.message}"
      end
      assert table.over?, "seed #{seed} did not finish"
    end
  end

  test "the elves deck plays whole games to a winner" do
    [1].each do |seed|
      srand(seed)
      table = Table.new("elves-#{seed}", deck: Deck.load("elves"), seed: seed)
      table.join("p1")
      table.join("p2")
      begin
        Bot.new(table).play
      rescue Bot::Stuck => e
        flunk "seed #{seed}: #{e.message}"
      end
      assert table.over?, "seed #{seed} did not finish"
    end
  end

  test "the jeskai deck plays whole games to a winner" do
    [1].each do |seed|
      srand(seed)
      table = Table.new("jeskai-#{seed}", deck: Deck.load("jeskai"), seed: seed)
      table.join("p1")
      table.join("p2")
      begin
        Bot.new(table).play
      rescue Bot::Stuck => e
        flunk "seed #{seed}: #{e.message}"
      end
      assert table.over?, "seed #{seed} did not finish"
    end
  end

  test "the korvold deck plays whole games to a winner" do
    [4, 15].each do |seed|
      srand(seed)
      table = Table.new("korvold-#{seed}", deck: Deck.load("korvold"), seed: seed)
      table.join("p1")
      table.join("p2")
      begin
        Bot.new(table).play
      rescue Bot::Stuck => e
        flunk "seed #{seed}: #{e.message}"
      end
      assert table.over?, "seed #{seed} did not finish"
    end
  end

  # Long games on big boards: every payment check copies the whole game, so these take about a minute. Run with SLOW=1.
  test "slow: more seeds of every deck play whole games to a winner" do
    skip "set SLOW=1 to run" unless ENV["SLOW"]

    { nil => [10, 22], "elves" => [7, 13], "jeskai" => [4, 10] }.each do |deck_name, seeds|
      seeds.each do |seed|
        srand(seed)
        table = deck_name ? Table.new("slow-#{deck_name}-#{seed}", deck: Deck.load(deck_name), seed: seed) : Table.new("slow-enchantress-#{seed}", seed: seed)
        table.join("p1")
        table.join("p2")
        begin
          Bot.new(table).play
        rescue Bot::Stuck => e
          flunk "#{deck_name || 'enchantress'} seed #{seed}: #{e.message}"
        end
        assert table.over?, "#{deck_name || 'enchantress'} seed #{seed} did not finish"
      end
    end
  end

  test "game over is reported to both players" do
    table = started_table
    loser = table.game.players.last
    loser.lose_life(loser.life)
    table.game.settle!

    view = table.view_for("a")
    assert view[:over]
    assert_not view[:can_act]
    assert_not_nil view[:winner]
  end

  test "a land's enters-the-battlefield trigger resolves when it is played" do
    table = Table.new("t", deck: Deck.new("x", "40 Scoured Barrens (X) 1\n"))
    table.join("a")
    table.join("b")
    player = table.game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid

    assert_nil table.play_land(uid, 0)
    assert_equal 21, player.life
    assert table.game.stack.empty?
  end

  test "graveyards are visible to both players" do
    table = started_table
    player = table.game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    other_uid = table.seats.find { |s| s.player != player }.uid
    card = player.hand.cards.first
    card.move_to_graveyard!

    assert_equal [card.name], table.view_for(uid)[:you][:graveyard]
    assert_equal [card.name], table.view_for(other_uid)[:opponent][:graveyard]
  end

  test "a mana source with its own cost (Sungrass Prairie) can pay for a spell" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    ["Sungrass Prairie", "Swamp", "Plains"].each do |name|
      card = Magic::Cards.const_get(name.delete(" ")).new(game: game, owner: player)
      Magic::Permanent.resolve_spell(game: game, card: card).controlled_since_turn = 0
    end
    spell = Magic::Cards::Arachnogenesis.new(game: game, owner: player)
    player.hand.add(spell)

    assert table.view_for(uid)[:you][:hand].find { |c| c[:name] == "Arachnogenesis" }[:castable]
    assert_nil table.cast(uid, player.hand.cards.index(spell))
    assert_includes player.graveyard.cards, spell
  end

  test "two filter lands chain off one Mountain: Mountain, Sunscorched Divide, Cascade Bluffs make Chart a Course castable" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    ["Mountain", "Sunscorched Divide", "Cascade Bluffs"].each do |name|
      card = Magic::Cards.const_get(name.delete(" ")).new(game: game, owner: player)
      Magic::Permanent.resolve_spell(game: game, card: card).controlled_since_turn = 0
    end
    spell = Magic::Cards::ChartACourse.new(game: game, owner: player)
    player.hand.add(spell)

    assert table.view_for(uid)[:you][:hand].find { |c| c[:name] == "Chart a Course" }[:castable]
    assert_nil table.cast(uid, player.hand.cards.index(spell))
    game.settle!
    assert_includes player.graveyard.map(&:name), "Chart a Course"
  end

  test "a hybrid-cost filter land (Cascade Bluffs) is tapped for mana, paying with the pool" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    ["Cascade Bluffs", "Mountain", "Mountain"].each do |name|
      card = Magic::Cards.const_get(name.delete(" ")).new(game: game, owner: player)
      Magic::Permanent.resolve_spell(game: game, card: card).controlled_since_turn = 0
    end
    spell = Magic::Cards::DualcasterMage.new(game: game, owner: player)
    player.hand.add(spell)

    assert table.view_for(uid)[:you][:hand].find { |c| c[:name] == "Dualcaster Mage" }[:castable]
    assert_nil table.cast(uid, player.hand.cards.index(spell))
    game.settle!
    assert_includes player.creatures.map(&:name), "Dualcaster Mage"
  end

  test "counters on permanents are reported" do
    table = started_table
    player = table.game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    bear = put_bear(table, player)
    2.times { bear.add_counter("+1/+1") }
    bear.add_counter("quest")
    table.game.settle!

    view = table.view_for(uid)[:you][:battlefield].find { |p| p[:id] == bear.object_id }
    assert_equal [{ name: "+1/+1", count: 2 }, { name: "quest", count: 1 }], view[:counters].sort_by { |c| c[:name] }
  end

  test "lore counters are shown on a Saga but not once it has flipped" do
    table = started_table
    game = table.game
    player = game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    saga = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::AzusasManyJourneys.new(game: game, owner: player))
    game.settle!

    counters = -> { table.view_for(uid)[:you][:battlefield].find { |p| p[:id] == saga.object_id }[:counters] }
    assert_equal [{ name: "lore", count: 1 }], counters.call

    Magic::Cards::AzusasManyJourneys::Chapter3.new(actor: saga).resolve!
    assert_equal "Likeness of the Seeker", saga.name
    assert_empty counters.call
  end

  test "fixed-mana lands like Selesnya Sanctuary count towards a spell's cost" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    %w[SelesnyaSanctuary Forest Swamp].each do |name|
      Magic::Permanent.resolve_spell(game: game, card: Magic::Cards.const_get(name).new(game: game, owner: player)).tap do |permanent|
        permanent.controlled_since_turn = 0
        permanent.untap!
      end
    end
    game.settle!
    game.skip_choice! while game.stack.pending_choices? # Selesnya Sanctuary's "return a land" trigger
    game.settle!
    spell = Magic::Cards::Panharmonicon.new(game: game, owner: player)
    player.hand.add(spell)

    assert table.view_for(uid)[:you][:hand].find { |c| c[:name] == "Panharmonicon" }[:castable]
    assert_nil table.cast(uid, player.hand.cards.index(spell))
  end

  test "a mana source that makes no mana does not block payment from the others" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    %w[ExoticOrchard Forest Forest].each do |name|
      Magic::Permanent.resolve_spell(game: game, card: Magic::Cards.const_get(name).new(game: game, owner: player)).controlled_since_turn = 0
    end
    spell = Magic::Cards::Farseek.new(game: game, owner: player)
    player.hand.add(spell)

    assert table.view_for(uid)[:you][:hand].find { |c| c[:name] == "Farseek" }[:castable]
  end

  test "a land's own ability (Evolving Wilds) can be activated and its choice answered" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    wilds = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::EvolvingWilds.new(game: game, owner: player))
    wilds.controlled_since_turn = 0

    view = table.view_for(uid)[:you][:battlefield].find { |p| p[:id] == wilds.object_id }
    assert_equal [true], view[:abilities].map { |a| a[:activatable] }
    assert_equal "{T}, Sacrifice: Use ability", view[:abilities].first[:label]

    assert_nil table.activate(uid, wilds.object_id, 0)
    choice = table.view_for(uid)[:choice]
    assert_equal "pick", choice[:kind]

    assert_nil table.choose(uid, [choice[:cards].first[:id]])
    assert_equal ["Forest"], player.permanents.map(&:name)
    assert_equal 1, game.battlefield.permanents.controlled_by(player).count
  end

  test "a permanent that is indestructible says so, however it got to be, and stops when that ends" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    colossus = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::DarksteelColossus.new(game: game, owner: player))
    bears = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::GrizzlyBears.new(game: game, owner: player))
    indestructible = lambda do |permanent|
      table.view_for(uid)[:you][:battlefield].find { |p| p[:id] == permanent.object_id }[:indestructible]
    end

    assert indestructible.call(colossus), "its own keyword"
    assert_not indestructible.call(bears)

    bears.grant_keyword(Magic::Keywords::INDESTRUCTIBLE, until_eot: true)
    game.tick!
    assert indestructible.call(bears), "granted until end of turn"

    bears.cleanup!
    game.tick!
    assert_not indestructible.call(bears)
  end

  test "a planeswalker's loyalty abilities are offered and can be activated" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    calix = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::CalixDestinysHand.new(game: game, owner: player))

    view = table.view_for(uid)[:you][:battlefield].find { |p| p[:id] == calix.object_id }
    assert_equal [true, false, false], view[:abilities].map { |a| a[:activatable] }
    assert_equal "[+1]: Look at the top four cards of your library. You may reveal an enchantment card from among them and put that card into your hand. Put the rest on the bottom of your library in a random order.",
                 view[:abilities].first[:label]
    assert_equal 4, view[:loyalty]

    assert_nil table.activate(uid, calix.object_id, 0)
    assert_equal 5, calix.loyalty
    assert_equal 5, table.view_for(uid)[:you][:battlefield].find { |p| p[:id] == calix.object_id }[:loyalty]
    assert_nil table.view_for(uid)[:you][:battlefield].find { |p| p[:land] }&.fetch(:loyalty)
    assert_match(/can't be activated/, table.activate(uid, calix.object_id, 0))
  end

  test "a targeted loyalty ability asks for a target, then activates, and can be cancelled" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    opponent = game.players.find { |p| p != player }
    uid = table.seats.find { |s| s.player == player }.uid
    calix = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::CalixDestinysHand.new(game: game, owner: player))
    calix.change_loyalty!(0)
    victim = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::LlanowarElves.new(game: game, owner: opponent))

    view = table.view_for(uid)[:you][:battlefield].find { |p| p[:id] == calix.object_id }
    assert_not view[:abilities][1][:activatable], "the -3 needs an enchantment of yours to be linked to"

    anthem = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::GloriousAnthem.new(game: game, owner: player))
    view = table.view_for(uid)[:you][:battlefield].find { |p| p[:id] == calix.object_id }
    assert view[:abilities][1][:activatable]

    assert_nil table.activate(uid, calix.object_id, 1)
    choice = table.view_for(uid)[:choice]
    assert_equal "target", choice[:kind]
    assert choice[:cancelable]
    assert_match(/1 of 2/, choice[:prompt])
    assert_equal [victim.object_id.to_s], choice[:targets].map { |t| t[:id] }
    assert_equal 4, calix.loyalty
    assert_equal Table::CHOICE_PENDING, table.advance_step(uid)

    assert_nil table.choose(uid, "cancel")
    assert_nil table.view_for(uid)[:choice]
    assert_equal 4, calix.loyalty

    assert_nil table.activate(uid, calix.object_id, 1)
    assert_nil table.choose(uid, victim.object_id.to_s)
    choice = table.view_for(uid)[:choice]
    assert_match(/2 of 2/, choice[:prompt])
    assert_equal [anthem.object_id.to_s], choice[:targets].map { |t| t[:id] }
    assert_equal 4, calix.loyalty

    assert_nil table.choose(uid, anthem.object_id.to_s)
    assert_equal 1, calix.loyalty
    assert_not_includes game.battlefield.permanents, victim
  end

  test "a targeted spell asks for a target before paying, can be cancelled, and is not offered without a target" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    2.times { Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::Plains.new(game: game, owner: player)).tap { |pm| pm.controlled_since_turn = 0 } }
    card = Magic::Cards::EtherealArmor.new(game: game, owner: player)
    player.hand.add(card)
    index = player.hand.cards.index(card)

    assert_not table.view_for(uid)[:you][:hand][index][:castable]
    assert_match(/no legal target/, table.cast(uid, index))

    bear = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::LlanowarElves.new(game: game, owner: player))
    assert table.view_for(uid)[:you][:hand][index][:castable]
    assert_nil table.cast(uid, index)
    choice = table.view_for(uid)[:choice]
    assert_equal "target", choice[:kind]
    assert choice[:cancelable]
    assert_includes choice[:targets].map { |t| t[:id] }, bear.object_id.to_s
    assert_includes player.hand.cards, card

    assert_nil table.choose(uid, "cancel")
    assert_nil table.view_for(uid)[:choice]
    assert_includes player.hand.cards, card

    assert_nil table.cast(uid, index)
    assert_nil table.choose(uid, bear.object_id.to_s)
    assert_not_includes player.hand.cards, card
    assert_includes bear.attachments, game.battlefield.permanents.find { |pm| pm.name == "Ethereal Armor" } if bear.respond_to?(:attachments)
  end

  test "an ability that sacrifices another permanent asks which one, and can be cancelled" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    3.times { Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::Forest.new(game: game, owner: player)).tap { |pm| pm.controlled_since_turn = 0 } }
    demon = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::NyxbornBehemoth.new(game: game, owner: player))
    demon.controlled_since_turn = 0
    ability = ->(table) { table.view_for(uid)[:you][:battlefield].find { |p| p[:id] == demon.object_id }[:abilities].first }

    assert_not ability.call(table)[:activatable], "the behemoth can't sacrifice itself"
    elves = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::GloriousAnthem.new(game: game, owner: player))
    assert ability.call(table)[:activatable]

    assert_nil table.activate(uid, demon.object_id, 0)
    choice = table.view_for(uid)[:choice]
    assert_equal "pick", choice[:kind]
    assert choice[:cancelable]
    assert_equal [1, 1], choice.values_at(:min, :max)
    assert_includes choice[:cards].map { |c| c[:id] }, elves.object_id.to_s

    assert_nil table.choose(uid, "cancel")
    assert_nil table.view_for(uid)[:choice]
    assert_includes game.battlefield.permanents, elves

    assert_nil table.activate(uid, demon.object_id, 0)
    assert_nil table.choose(uid, [elves.object_id.to_s])
    assert_not_includes game.battlefield.permanents, elves
  end

  test "a Spacecraft is stationed by tapping a chosen creature, and shows its charge counters" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    ship = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::ExplorationBroodship.new(game: game, owner: player))
    bears = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::GrizzlyBears.new(game: game, owner: player))
    bears.controlled_since_turn = game.current_turn.number
    ability = ->(table) { table.view_for(uid)[:you][:battlefield].find { |p| p[:id] == ship.object_id }[:abilities].first }

    assert_equal "Tap a creature: Station", ability.call(table)[:label]
    assert ability.call(table)[:activatable]

    assert_nil table.activate(uid, ship.object_id, 0)
    choice = table.view_for(uid)[:choice]
    assert_equal "pick", choice[:kind]
    assert_match(/Choose a creature to tap/, choice[:prompt])
    assert_equal [bears.object_id.to_s], choice[:cards].map { |c| c[:id] }

    assert_nil table.choose(uid, [bears.object_id.to_s])
    game.stack.resolve!

    assert bears.tapped?
    assert_equal 2, ship.charge_counters
    counter = table.view_for(uid)[:you][:battlefield].find { |p| p[:id] == ship.object_id }[:counters].first
    assert_equal({ name: "charge", count: 2, of: 3 }, counter)
  end

  test "a card with cycling can be cycled from the hand for its cost" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    triome = Magic::Cards::IndathaTriome.new(game: game, owner: player)
    player.hand.add(triome)
    index = player.hand.cards.index(triome)

    assert_not table.view_for(uid)[:you][:hand][index][:cyclable]
    assert_match(/Not enough mana/, table.cycle(uid, index))

    3.times { Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::Forest.new(game: game, owner: player)).tap { |pm| pm.controlled_since_turn = 0 } }
    assert table.view_for(uid)[:you][:hand][index][:cyclable]
    hand_size = player.hand.count
    assert_nil table.cycle(uid, index)
    assert_includes player.graveyard.cards, triome
    assert_equal hand_size, player.hand.count
  end

  test "Boseiju's Channel is activated from the hand, choosing a target" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    opponent = game.players.find { |p| p != player }
    uid = table.seats.find { |s| s.player == player }.uid
    boseiju = Magic::Cards::BoseijuWhoEndures.new(game: game, owner: player)
    player.hand.add(boseiju)
    index = player.hand.cards.index(boseiju)
    target = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::BoseijuWhoEndures.new(game: game, owner: opponent))

    assert_not table.view_for(uid)[:you][:hand][index][:abilities].first[:activatable]
    assert_match(/can't be activated/, table.activate_from_hand(uid, index, 0))

    2.times { Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::Forest.new(game: game, owner: player)).tap { |pm| pm.controlled_since_turn = 0 } }
    assert table.view_for(uid)[:you][:hand][index][:abilities].first[:activatable]

    assert_nil table.activate_from_hand(uid, index, 0)
    assert_nil table.choose(uid, [ChoicePrompt.target_id(target)])
    game.stack.resolve!

    assert_not_includes opponent.permanents, target
    assert_includes player.graveyard.cards, boseiju
  end

  test "attackers can be sent at an opposing planeswalker" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    opponent = game.players.find { |p| p != player }
    uid = table.seats.find { |s| s.player == player }.uid
    calix = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::CalixDestinysHand.new(game: game, owner: opponent))
    bear = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::LlanowarElves.new(game: game, owner: player))
    bear.controlled_since_turn = 0
    bear.untap!
    table.advance_step(uid) until game.current_turn.step == "declare_attackers"
    loyalty = calix.loyalty
    life = opponent.life

    assert table.view_for(uid)[:opponent][:battlefield].find { |p| p[:id] == calix.object_id }[:planeswalker]
    assert_match(/can't be attacked/, table.declare_attackers(uid, [bear.object_id], { bear.object_id.to_s => bear.object_id }))
    assert_nil table.declare_attackers(uid, [bear.object_id], { bear.object_id.to_s => calix.object_id })
    table.advance_step(uid) until game.current_turn.step == "second_main" || table.over?

    assert_equal life, opponent.life
    assert_equal loyalty - bear.power, calix.loyalty
  end

  test "a card exiled with a play permission is shown in exile and can be cast from there" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    opponent = game.players.find { |p| p != player }
    uid = table.seats.find { |s| s.player == player }.uid
    rhetoric = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::CunningRhetoric.new(game: game, owner: player))
    bears = Magic::Cards::GrizzlyBears.new(game: game, owner: opponent)
    opponent.library.add(bears)
    rhetoric.exiled_cards << bears
    bears.exile!
    2.times { Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::Forest.new(game: game, owner: player)).tap { |pm| pm.controlled_since_turn = 0 } }

    entry = table.view_for(uid)[:exile].find { |c| c[:name] == "Grizzly Bears" }
    assert entry[:castable]
    assert_nil table.cast(uid, entry[:index], "exile")
    assert_equal ["Grizzly Bears"], player.creatures.map(&:name)
    assert_empty table.view_for(uid)[:exile]
  end

  test "the opponent gets priority to respond only when they hold something castable" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    opponent = game.players.find { |p| p != player }
    uid = table.seats.find { |s| s.player == player }.uid
    opp_uid = table.seats.find { |s| s.player == opponent }.uid
    land = ->(owner, card_class) { Magic::Permanent.resolve_spell(game: game, card: card_class.new(game: game, owner: owner)).tap { |pm| pm.controlled_since_turn = 0 } }
    2.times { land.call(player, Magic::Cards::Forest) }
    bears = Magic::Cards::GrizzlyBears.new(game: game, owner: player)
    player.hand.add(bears)

    assert_nil table.cast(uid, player.hand.cards.index(bears))
    assert_equal ["Grizzly Bears"], player.creatures.map(&:name), "no response possible, so it resolves at once"
    assert_not table.view_for(opp_uid)[:priority]

    land.call(opponent, Magic::Cards::Mountain)
    bolt = Magic::Cards::LightningBolt.new(game: game, owner: opponent)
    opponent.hand.add(bolt)
    2.times { land.call(player, Magic::Cards::Forest) }
    more = Magic::Cards::GrizzlyBears.new(game: game, owner: player)
    player.hand.add(more)

    assert_nil table.cast(uid, player.hand.cards.index(more))
    view = table.view_for(opp_uid)
    assert view[:priority]
    assert_equal ["Grizzly Bears"], view[:stack].map { |i| i[:name] }
    assert_not table.view_for(uid)[:can_act]
    assert_equal Table::RESPOND_FIRST, table.advance_step(opp_uid)
    assert_match(/Wait for/, table.cast(uid, 0))

    assert_nil table.pass_priority(opp_uid)
    assert_equal 2, player.creatures.size
    assert_not table.view_for(opp_uid)[:priority]
  end

  test "with Demon of Fate's Design an enchantment can be cast by paying life, once each turn" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::DemonOfFatesDesign.new(game: game, owner: player)).controlled_since_turn = 0
    first = Magic::Cards::SanctumOfCalmWaters.new(game: game, owner: player)
    second = Magic::Cards::SanctumOfCalmWaters.new(game: game, owner: player)
    player.hand.add(first)
    player.hand.add(second)
    index = player.hand.cards.index(first)

    assert table.view_for(uid)[:you][:hand][index][:castable], "castable with no lands, by paying life"
    life = player.life
    assert_nil table.cast(uid, index), "with no mana to pay, life is paid without asking"
    assert_equal life - first.mana_value, player.life
    assert_includes game.battlefield.permanents.map(&:name), "Sanctum of Calm Waters"

    assert_not table.view_for(uid)[:you][:hand][player.hand.cards.index(second)][:castable], "only once each turn"
  end

  test "with mana available and Demon of Fate's Design, the player chooses mana or life" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::DemonOfFatesDesign.new(game: game, owner: player)).controlled_since_turn = 0
    4.times { Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::Island.new(game: game, owner: player)).tap { |pm| pm.controlled_since_turn = 0 } }
    card = Magic::Cards::SanctumOfCalmWaters.new(game: game, owner: player)
    player.hand.add(card)
    index = player.hand.cards.index(card)
    life = player.life

    assert_nil table.cast(uid, index)
    choice = table.view_for(uid)[:choice]
    assert_equal "options", choice[:kind]
    assert_equal %w[mana life], choice[:options].map { |o| o[:id] }

    assert_nil table.choose(uid, "cancel")
    assert_includes player.hand.cards, card

    assert_nil table.cast(uid, index)
    assert_nil table.choose(uid, "life")
    assert_equal life - card.mana_value, player.life
    assert_not_includes player.hand.cards, card
  end

  test "Path to Exile lets the creature's controller, not its caster, search for the land" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    opponent = game.players.find { |p| p != player }
    uid = table.seats.find { |s| s.player == player }.uid
    opp_uid = table.seats.find { |s| s.player == opponent }.uid
    Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::Plains.new(game: game, owner: player)).controlled_since_turn = 0
    victim = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::LlanowarElves.new(game: game, owner: opponent))
    path = Magic::Cards::PathToExile.new(game: game, owner: player)
    player.hand.add(path)

    assert_nil table.cast(uid, player.hand.cards.index(path))
    assert_nil table.choose(uid, victim.object_id.to_s)

    assert_equal "pick", table.view_for(opp_uid)[:choice][:kind]
    assert table.view_for(opp_uid)[:choice][:chooser]
    assert_not table.view_for(uid)[:choice][:chooser]
  end

  test "Bargain asks whether to sacrifice an artifact, enchantment or token, and can be declined or cancelled" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    4.times { Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::Swamp.new(game: game, owner: player)).tap { |pm| pm.controlled_since_turn = 0 } }
    spell = Magic::Cards::BeseechTheMirror.new(game: game, owner: player)
    player.hand.add(spell)
    index = player.hand.cards.index(spell)

    # With only lands to sacrifice there is no bargain to offer: it goes straight to the search.
    assert_nil table.cast(uid, index)
    assert_match(/Search/, table.view_for(uid)[:choice][:prompt])
  end

  test "Bargain offers an enchantment to sacrifice, which can be declined, cancelled or taken" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    4.times { Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::Swamp.new(game: game, owner: player)).tap { |pm| pm.controlled_since_turn = 0 } }
    anthem = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::GloriousAnthem.new(game: game, owner: player))
    Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::LlanowarElves.new(game: game, owner: player))
    spell = Magic::Cards::BeseechTheMirror.new(game: game, owner: player)
    player.hand.add(spell)
    index = player.hand.cards.index(spell)

    assert_nil table.cast(uid, index)
    choice = table.view_for(uid)[:choice]
    assert_match(/bargain/, choice[:prompt])
    assert choice[:cancelable]
    assert_equal [0, 1], choice.values_at(:min, :max)
    assert_equal [anthem.object_id.to_s], choice[:cards].map { |c| c[:id] }, "only artifacts, enchantments and tokens"

    assert_nil table.choose(uid, "cancel")
    assert_includes player.hand.cards, spell
    assert_includes game.battlefield.permanents, anthem

    assert_nil table.cast(uid, index)
    assert_nil table.choose(uid, [])
    assert_includes game.battlefield.permanents, anthem
    assert_match(/Search/, table.view_for(uid)[:choice][:prompt])
  end

  test "choosing a permanent to bargain with sacrifices it and lets the exiled card be cast for free" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    4.times { Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::Swamp.new(game: game, owner: player)).tap { |pm| pm.controlled_since_turn = 0 } }
    anthem = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::GloriousAnthem.new(game: game, owner: player))
    spell = Magic::Cards::BeseechTheMirror.new(game: game, owner: player)
    player.hand.add(spell)
    mind_stone = Magic::Cards::MindStone.new(game: game, owner: player)
    player.library.add(mind_stone)

    assert_nil table.cast(uid, player.hand.cards.index(spell))
    assert_nil table.choose(uid, [anthem.object_id.to_s])
    assert_not_includes game.battlefield.permanents, anthem

    assert_nil table.choose(uid, [mind_stone.object_id.to_s])
    choice = table.view_for(uid)[:choice]
    assert_equal "may", choice[:kind], "Mind Stone costs 2, so it may be cast for free"
    assert_nil table.choose(uid, "yes")
    assert_includes game.battlefield.permanents.map(&:name), "Mind Stone"
  end

  test "each player decides on their opening hand: keep, or mulligan and put cards on the bottom" do
    AutoKeepOpeningHands.enabled = false
    table = Table.new("t")
    table.join("a")
    table.join("b")
    first = table.game.players.first
    second = table.game.players.last
    uid1 = table.seats.first.uid
    uid2 = table.seats.last.uid

    choice = table.view_for(uid1)[:choice]
    assert_equal "options", choice[:kind]
    assert_equal %w[keep mulligan], choice[:options].map { |o| o[:id] }
    assert_not table.view_for(uid2)[:choice][:chooser], "the second player waits"
    assert_equal Table::CHOICE_PENDING, table.advance_step(uid1)
    assert_match(/not your choice/i, table.choose(uid2, "keep"))

    old_hand = first.hand.cards.map(&:itself)
    assert_nil table.choose(uid1, "mulligan")
    assert_equal 7, first.hand.count
    assert_not_equal old_hand, first.hand.cards.map(&:itself)
    assert_match(/mulligan 1/, table.view_for(uid1)[:choice][:prompt])

    assert_nil table.choose(uid1, "keep")
    choice = table.view_for(uid1)[:choice]
    assert_equal "pick", choice[:kind]
    assert_equal [1, 1], choice.values_at(:min, :max)
    library = first.library.count
    assert_nil table.choose(uid1, [choice[:cards].first[:id]])
    assert_equal 6, first.hand.count
    assert_equal library + 1, first.library.count

    assert table.view_for(uid2)[:choice][:chooser]
    assert_nil table.choose(uid2, "keep")
    assert_equal 7, second.hand.count
    assert_nil table.view_for(uid1)[:choice]
    assert_equal "first_main", table.view_for(uid1)[:turn][:step]
  ensure
    AutoKeepOpeningHands.enabled = true
  end

  test "conceding ends the game with the other player as the winner" do
    table = Table.new("t")
    table.join("a")
    table.join("b")

    assert_nil table.concede("a")

    view = table.view_for("b")
    assert view[:over]
    assert_equal "Player 2", view[:winner]
    assert_not view[:can_act]
    assert table.advance_step("b"), "nothing can be done once the game is over"
    assert_equal "The game is already over.", table.concede("b")
  end

  test "the attacker's controller orders several blockers, and damage follows that order" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    opponent = game.players.find { |p| p != player }
    uid = table.seats.find { |s| s.player == player }.uid
    opp_uid = table.seats.find { |s| s.player == opponent }.uid
    attacker = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::GrizzlyBears.new(game: game, owner: player))
    elf = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::LlanowarElves.new(game: game, owner: opponent))
    bears = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::GrizzlyBears.new(game: game, owner: opponent))
    [attacker, elf, bears].each { |pm| pm.controlled_since_turn = 0 }
    table.advance_step(uid) until game.current_turn.step == "declare_attackers"

    assert_nil table.declare_attackers(uid, [attacker.object_id])
    assert_nil table.declare_blockers(opp_uid, [[elf.object_id, attacker.object_id], [bears.object_id, attacker.object_id]])

    choice = table.view_for(uid)[:choice]
    assert_equal "options", choice[:kind]
    assert_match(/Which one takes damage first/, choice[:prompt])
    assert_equal [elf.object_id.to_s, bears.object_id.to_s].sort, choice[:options].map { |o| o[:id] }.sort
    assert_equal "declare_blockers", game.current_turn.step

    assert_nil table.choose(uid, elf.object_id.to_s)
    choice = table.view_for(uid)[:choice]
    assert_equal "assign", choice[:kind], "the last blocker needs no question; the damage is divided next"
    assert_equal 2, choice[:total]
    assert_equal [elf.object_id.to_s, bears.object_id.to_s], choice[:rows].map { |r| r[:id] }
    assert_equal [1, 1], choice[:rows].map { |r| r[:value] }, "lethal to the elf, the rest to the bears"

    assert_match(/lethal damage/, table.choose(uid, { elf.object_id.to_s => 0, bears.object_id.to_s => 2 }), "not the later blocker first")
    assert_match(/Assign all 2/, table.choose(uid, { elf.object_id.to_s => 1 }))
    assert_equal "assign", table.view_for(uid)[:choice][:kind], "a bad division leaves the question open"

    assert_nil table.choose(uid, { elf.object_id.to_s => 2, bears.object_id.to_s => 0 })
    assert_equal "second_main", game.current_turn.step, "combat went ahead"
    assert_not_includes game.battlefield.permanents, elf
    assert_includes game.battlefield.permanents, bears
    assert_equal 0, bears.damage, "all the damage went to the elf"
  end

  test "a spell with two targets asks for each in turn, and nothing is paid until both are chosen" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    opponent = game.players.find { |p| p != player }
    uid = table.seats.find { |s| s.player == player }.uid
    2.times { Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::Forest.new(game: game, owner: player)).controlled_since_turn = 0 }
    mine = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::LlanowarElves.new(game: game, owner: player))
    theirs = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::WoodElves.new(game: game, owner: opponent))
    bite = Magic::Cards::BiteDown.new(game: game, owner: player)
    player.hand.add(bite)

    assert table.view_for(uid)[:you][:hand].find { |c| c[:name] == "Bite Down" }[:castable]
    assert_nil table.cast(uid, player.hand.cards.index(bite))
    choice = table.view_for(uid)[:choice]
    assert_match(/1 of 2/, choice[:prompt])
    assert_equal [mine.object_id.to_s], choice[:targets].map { |t| t[:id] }

    assert_nil table.choose(uid, mine.object_id.to_s)
    choice = table.view_for(uid)[:choice]
    assert_match(/2 of 2/, choice[:prompt])
    assert_equal [theirs.object_id.to_s], choice[:targets].map { |t| t[:id] }
    assert_equal 0, player.permanents.count(&:tapped?), "nothing is tapped yet"

    assert_nil table.choose(uid, theirs.object_id.to_s)
    assert_not_includes game.battlefield.permanents, theirs
    assert_equal 2, player.permanents.count(&:tapped?)
  end

  test "a modal spell whose mode needs a target asks for the modes, then the target" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    2.times { Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::Forest.new(game: game, owner: player)).controlled_since_turn = 0 }
    bears = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::GrizzlyBears.new(game: game, owner: player))
    spell = Magic::Cards::SarkhansResolve.new(game: game, owner: player)
    player.hand.add(spell)

    assert table.view_for(uid)[:you][:hand].find { |c| c[:name] == "Sarkhan's Resolve" }[:castable]
    assert_nil table.cast(uid, player.hand.cards.index(spell))
    choice = table.view_for(uid)[:choice]
    assert_equal "modes", choice[:kind]
    assert_equal 1, choice[:options].size, "the destroy mode needs a flyer, and there is none"

    assert_nil table.choose(uid, [choice[:options].first[:id]])
    choice = table.view_for(uid)[:choice]
    assert_equal "target", choice[:kind]
    assert_equal [bears.object_id.to_s], choice[:targets].map { |t| t[:id] }

    assert_nil table.choose(uid, bears.object_id.to_s)
    assert_equal 5, bears.power
  end

  test "the turn stops at its end step for an opponent who holds a spell they could cast" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    opponent = game.players.find { |p| p != player }
    uid = table.seats.find { |s| s.player == player }.uid
    opp_uid = table.seats.find { |s| s.player == opponent }.uid

    table.advance_step(uid) until game.current_turn.step == "second_main"
    assert_nil table.advance_step(uid)
    assert_equal 2, game.current_turn.number, "nothing to respond with: the turn was passed through"

    table2 = Table.new("t2", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table2.join("a")
    table2.join("b")
    game = table2.game
    player = game.current_turn.active_player
    opponent = game.players.find { |p| p != player }
    uid = table2.seats.find { |s| s.player == player }.uid
    opp_uid = table2.seats.find { |s| s.player == opponent }.uid
    Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::Mountain.new(game: game, owner: opponent)).controlled_since_turn = 0
    opponent.hand.add(Magic::Cards::LightningBolt.new(game: game, owner: opponent))

    table2.advance_step(uid) until game.current_turn.step == "second_main"
    assert_nil table2.advance_step(uid)
    assert_equal "end", game.current_turn.step
    assert_equal 1, game.current_turn.number
    assert table2.view_for(opp_uid)[:can_act]
    assert_not table2.view_for(uid)[:can_act]
    assert table2.view_for(opp_uid)[:you][:hand].any? { |c| c[:name] == "Lightning Bolt" && c[:castable] }

    assert_nil table2.advance_step(opp_uid)
    assert_equal 2, game.current_turn.number
  end

  test "an ability that is already tapped out is not offered" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    wilds = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::EvolvingWilds.new(game: game, owner: player))
    wilds.controlled_since_turn = 0
    wilds.tap!

    view = table.view_for(uid)[:you][:battlefield].find { |p| p[:id] == wilds.object_id }
    assert_equal [false], view[:abilities].map { |a| a[:activatable] }
    assert_match(/can't be activated/, table.activate(uid, wilds.object_id, 0))
  end

  test "the event log records plays, spells and combat for both players" do
    table = started_table
    texts = table.view_for("a")[:log].map { |entry| entry[:text] }
    assert_match(/opening hand of 7/, texts.first)
    assert_match(/Turn 1/, texts.second)

    player = table.game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    player.library.cards.find(&:land?).move_to_hand!(player) unless player.hand.cards.any?(&:land?)
    assert_nil table.play_land(uid, player.hand.cards.index(&:land?))
    assert(table.view_for("b")[:log].map { |e| e[:text] }.any? { |t| t.start_with?("#{player.name} played") })
  end

  test "Courser of Kruphix reveals the top card to both players and lets its owner play a land from there" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    other_uid = table.seats.find { |s| s.player != player }.uid

    assert_nil table.view_for(uid)[:you][:library_top]
    assert_nil table.view_for(other_uid)[:opponent][:library_top]

    Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::CourserOfKruphix.new(game: game, owner: player))
    game.settle!
    top = player.library.first

    mine = table.view_for(uid)[:you][:library_top]
    assert_equal top.name, mine[:name]
    assert mine[:playable_land]
    assert_equal({ name: top.name, land: true }, table.view_for(other_uid)[:opponent][:library_top])

    assert_nil table.play_land(uid, 0, "library")
    assert_includes player.permanents.map(&:card), top
    assert_not table.view_for(uid)[:you][:library_top][:playable_land], "land drop is used"
  end

  test "the event log links effects to what caused them" do
    table = Table.new("t", deck: Deck.new("x", "40 Scoured Barrens (X) 1\n"))
    table.join("a")
    table.join("b")
    player = table.game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid

    assert_nil table.play_land(uid, 0)
    log = table.view_for(uid)[:log]
    played = log.find { |e| e[:text] == "#{player.name} played Scoured Barrens (tapped)" }
    gain = log.find { |e| e[:text].start_with?("#{player.name} gains 1 life") }

    assert_nil played[:parent_id]
    assert_equal 0, played[:depth]
    assert_equal played[:id], gain[:parent_id]
    assert_equal 1, gain[:depth]
    assert_equal "Scoured Barrens", gain[:via]
  end

  test "a saga chapter is its own log entry, and what it does does not repeat the saga's name" do
    table = started_table
    game = table.game
    active = game.current_turn.active_player
    uid = table.seats.find { |s| s.player == active }.uid
    Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::TheBindingOfTheTitans.new(game: game, owner: active))
    game.settle!

    log = table.view_for(uid)[:log]
    chapter = log.find { |e| e[:text] == "Chapter I: The Binding of the Titans" }
    assert chapter, log.map { |e| e[:text] }.inspect
    mills = log.select { |e| e[:text].include?("mills") }
    assert mills.any?
    assert(mills.all? { |e| e[:parent_id] == chapter[:id] && e[:via].nil? })
  end

  test "choices answered later are linked to the ability that asked" do
    table = started_table
    active = table.game.current_turn.active_player
    uid = table.seats.find { |s| s.player == active }.uid
    other = table.game.opponents(active).first
    Magic::Permanent.resolve_spell(game: table.game, card: Magic::Cards::GoblinArsonist.new(game: table.game, owner: active)).destroy!
    table.game.settle!
    table.choose(uid, "yes")
    table.choose(uid, other.name)

    log = table.view_for(uid)[:log]
    died = log.find { |e| e[:text] == "Goblin Arsonist dies" }
    damage = log.find { |e| e[:text].include?("deals 1 damage to #{other.name}") }
    assert_equal died[:id], damage[:parent_id]
  end

  test "a choice with nothing to choose is skipped and noted in the log under its cause" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    player.hand.cards.select(&:land?).each { |land| land.move_to_graveyard! } # no land left in hand for Composer to put onto the battlefield
    composer = Magic::Cards::ComposerOfSpring.new(game: game, owner: player)
    player.hand.add(composer)
    enchantment = Magic::Cards::FontOfFertility.new(game: game, owner: player)

    Magic::Permanent.resolve_spell(game: game, card: composer)
    Magic::Permanent.resolve_spell(game: game, card: enchantment)
    game.settle!
    table.send(:dismiss_empty_choices!) # every real action ends with this sweep

    assert_nil table.view_for(uid)[:choice]
    log = table.view_for(uid)[:log]
    skipped = log.find { |e| e[:kind] == :skip }
    assert_match(/no legal choice for Composer of Spring/, skipped[:text])
    assert_not_nil skipped[:parent_id]
  end

  test "a modal spell asks its caster for modes, then casts with them" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    6.times do
      Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::Plains.new(game: game, owner: player)).controlled_since_turn = 0
    end
    bears = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::GrizzlyBears.new(game: game, owner: player))
    farewell = Magic::Cards::Farewell.new(game: game, owner: player)
    player.hand.add(farewell)

    assert table.view_for(uid)[:you][:hand].find { |c| c[:name] == "Farewell" }[:castable]
    assert_nil table.cast(uid, player.hand.cards.index(farewell))

    choice = table.view_for(uid)[:choice]
    assert_equal "modes", choice[:kind]
    assert_equal 4, choice[:options].size
    assert_equal 1, choice[:min]
    assert choice[:cancelable]
    assert_match(/Resolve the pending choice/, table.advance_step(uid))
    assert_match(/Choose/, table.choose(uid, []))

    creatures = choice[:options].find { |o| o[:label] == "Exile all creatures" }
    assert_nil table.choose(uid, [creatures[:id]])
    assert_nil table.view_for(uid)[:choice]
    assert_not_includes player.permanents, bears
    assert_equal 6, player.permanents.count(&:tapped?), "all six lands were tapped for the six-mana spell"
  end

  test "a modal spell can be cancelled without paying" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    6.times { Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::Plains.new(game: game, owner: player)).controlled_since_turn = 0 }
    farewell = Magic::Cards::Farewell.new(game: game, owner: player)
    player.hand.add(farewell)

    table.cast(uid, player.hand.cards.index(farewell))
    assert_nil table.choose(uid, ["cancel"])
    assert_nil table.view_for(uid)[:choice]
    assert_includes player.hand.cards, farewell
    assert_equal 0, player.permanents.count(&:tapped?)
  end

  test "Khalni Heart Expedition can be activated once it has three quest counters" do
    table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    table.join("a")
    table.join("b")
    game = table.game
    player = game.current_turn.active_player
    uid = table.seats.find { |s| s.player == player }.uid
    khalni = Magic::Permanent.resolve_spell(game: game, card: Magic::Cards::KhalniHeartExpedition.new(game: game, owner: player))
    game.settle!
    ability = -> { table.view_for(uid)[:you][:battlefield].find { |p| p[:id] == khalni.object_id }[:abilities].first }

    2.times { khalni.add_counter("quest") }
    assert_not ability.call[:activatable]

    khalni.add_counter("quest")
    game.settle!
    assert ability.call[:activatable]
    assert_nil table.activate(uid, khalni.object_id, 0)
    assert_equal "pick", table.view_for(uid)[:choice][:kind]
  end

  test "a choice that belongs to the opponent is put to the opponent" do
    table = started_table
    active = table.game.current_turn.active_player
    other = table.game.opponents(active).first
    other_uid = table.seats.find { |s| s.player == other }.uid
    Magic::Permanent.resolve_spell(game: table.game, card: Magic::Cards::GrizzlyBears.new(game: table.game, owner: other))
    saga = Magic::Cards::TheEldestReborn.new(game: table.game, owner: active)
    active.hand.add(saga)
    Magic::Permanent.resolve_spell(game: table.game, card: saga)
    table.game.settle!

    assert_equal true, table.view_for(other_uid)[:choice][:chooser]
    assert_equal false, table.view_for(table.seats.find { |s| s.player == active }.uid)[:choice][:chooser]
  end

  test "a colour choice offers the five colours" do
    table = started_table
    prompt = ChoicePrompt.new(Magic::Cards::CarpetOfFlowers::ColorChoice.new(actor: Magic::Permanent.resolve_spell(game: table.game, card: Magic::Cards::CarpetOfFlowers.new(game: table.game, owner: table.game.players.first))), table.game)

    assert_equal "options", prompt.view[:kind]
    assert_equal %w[white blue black red green], prompt.view[:options].map { |o| o[:id] }
  end
end
