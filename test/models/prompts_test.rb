require "test_helper"

# The prompts the table asks for the less common things a card can want: several answers to one choice, X, additional and
# optional costs, paying mana for a choice, names of creature types, and abilities used from the graveyard.
class PromptsTest < ActiveSupport::TestCase
  setup do
    @table = Table.new("t", deck: Deck.new("x", "40 Forest (X) 1\n"))
    @table.join("a")
    @table.join("b")
    @game = @table.game
    @player = @game.current_turn.active_player
    @opponent = @game.players.find { |p| p != @player }
    @uid = @table.seats.find { |s| s.player == @player }.uid
  end

  def put(card_class, owner = @player, summoning_sick: false)
    permanent = Magic::Permanent.resolve_spell(game: @game, card: card_class.new(game: @game, owner: owner))
    permanent.controlled_since_turn = 0 unless summoning_sick
    permanent
  end

  def lands(card_class, count)
    count.times { put(card_class) }
  end

  def choice = @table.view_for(@uid)[:choice]

  def ids(entries) = entries.map { |entry| entry[:id] }

  test "Rootweaver Druid: the opponent picks three lands, then which one goes under the Druid's controller" do
    druid = put(Magic::Cards::RootweaverDruid)
    @game.settle! if @game.respond_to?(:settle!)
    opponent_uid = @table.seats.find { |seat| seat.player == @opponent }.uid
    opponent_choice = -> { @table.view_for(opponent_uid)[:choice] }

    assert_equal "pick", opponent_choice.call[:kind]
    assert_match(/up to three basic land cards/, opponent_choice.call[:prompt])
    found = opponent_choice.call[:cards].first(3)
    assert_nil @table.choose(opponent_uid, found.map { |card| card[:id] })

    second = opponent_choice.call
    assert_equal "pick", second[:kind]
    assert_match(/which land goes onto the battlefield under #{@player.name}'s control/, second[:prompt])
    assert_equal found.map { |card| card[:id] }.sort, second[:cards].map { |card| card[:id] }.sort
    assert_empty @player.permanents.lands, "nothing is put onto the battlefield until they have picked"

    assert_nil @table.choose(opponent_uid, [found.first[:id]])

    assert_equal 1, @player.permanents.lands.count
    assert_equal 2, @opponent.permanents.lands.count
    assert_nil @table.view_for(opponent_uid)[:choice]
    assert druid
  end

  test "a spell with an offspring cost asks whether to pay it, and pays for the token copy" do
    4.times { put(Magic::Cards::Mountain) }
    spell = Magic::Cards::AgateInstigator.new(game: @game, owner: @player)
    @player.hand.add(spell)

    assert_nil @table.cast(@uid, @player.hand.cards.index(spell))
    assert_match(/offspring/i, choice[:prompt])
    assert_equal %w[no yes], choice[:options].map { |option| option[:id] }
    assert_match(/\{1\}\{R\}/, choice[:options].last[:label])

    assert_nil @table.choose(@uid, ["yes"])

    assert_nil choice
    agates = @player.permanents.select { |permanent| permanent.name == "Agate Instigator" }
    assert_equal 2, agates.size, "the creature and its token copy"
    assert_equal 1, agates.count(&:token?)
    assert_equal 4, @player.permanents.lands.count(&:tapped?), "both costs, {1}{R} each, were paid"
  end

  test "an offspring cost declined casts the creature alone" do
    4.times { put(Magic::Cards::Mountain) }
    spell = Magic::Cards::AgateInstigator.new(game: @game, owner: @player)
    @player.hand.add(spell)

    assert_nil @table.cast(@uid, @player.hand.cards.index(spell))
    assert_nil @table.choose(@uid, ["no"])

    assert_equal ["Agate Instigator"], @player.permanents.reject { |permanent| permanent.card.land? }.map(&:name)
    assert_equal 2, @player.permanents.lands.count(&:tapped?)
  end

  test "with Zinnia, paying only the granted offspring pays {2}, not the card's own {1}{R}" do
    put(Magic::Cards::ZinniaValleysVoice)
    4.times { put(Magic::Cards::Forest) }
    spell = Magic::Cards::AgateInstigator.new(game: @game, owner: @player)
    @player.hand.add(spell)
    # Only one red source: the spell's own {R} is the only red mana there is, so the card's own offspring {1}{R} can't be paid.
    put(Magic::Cards::Mountain)

    assert_nil @table.cast(@uid, @player.hand.cards.index(spell))
    # The card's own offspring isn't affordable and is skipped without a question, so the granted cost is the one asked.
    assert_match(/2 of 2/, choice[:prompt])
    assert_match(/\{2\}/, choice[:options].last[:label])
    assert_nil @table.choose(@uid, ["yes"])

    agates = @player.permanents.select { |permanent| permanent.name == "Agate Instigator" }
    assert_equal 2, agates.size
    assert_equal 1, agates.count(&:token?)
    assert_equal 4, @player.permanents.lands.count(&:tapped?), "{1}{R} for the spell and {2} for the granted offspring"
  end

  test "an offspring cost that can't be afforded isn't asked about" do
    2.times { put(Magic::Cards::Mountain) }
    spell = Magic::Cards::AgateInstigator.new(game: @game, owner: @player)
    @player.hand.add(spell)

    assert_nil @table.cast(@uid, @player.hand.cards.index(spell))

    assert_nil choice
    assert_equal ["Agate Instigator"], @player.permanents.reject { |permanent| permanent.card.land? }.map(&:name)
  end

  test "a spell's choices say whether each thing is the chooser's or the opponent's" do
    2.times { put(Magic::Cards::Swamp) }
    4.times { put(Magic::Cards::Forest) }
    mine = put(Magic::Cards::Forest)
    theirs = put(Magic::Cards::Forest, @opponent)
    spell = Magic::Cards::CasualtiesOfWar.new(game: @game, owner: @player)
    @player.hand.add(spell)

    assert_nil @table.cast(@uid, @player.hand.cards.index(spell))
    land_mode = choice[:options].find { |option| option[:label] =~ /land/i }
    assert_nil @table.choose(@uid, [land_mode[:id]])

    cards = choice[:cards]
    assert_equal "pick", choice[:kind]
    assert_equal "yours", cards.find { |card| card[:id] == mine.object_id.to_s }[:side]
    assert_equal "opponent's", cards.find { |card| card[:id] == theirs.object_id.to_s }[:side]
  end

  test "a target on the board is labelled yours or opponent's" do
    lands(Magic::Cards::Forest, 2)
    mine = put(Magic::Cards::GrizzlyBears)
    theirs = put(Magic::Cards::GrizzlyBears, @opponent)
    spell = Magic::Cards::SarkhansResolve.new(game: @game, owner: @player)
    @player.hand.add(spell)

    assert_nil @table.cast(@uid, @player.hand.cards.index(spell))
    assert_nil @table.choose(@uid, [choice[:options].first[:id]])

    labels = choice[:targets].to_h { |target| [target[:id], target[:label]] }
    assert_equal "Grizzly Bears (yours)", labels[mine.object_id.to_s]
    assert_equal "Grizzly Bears (opponent's)", labels[theirs.object_id.to_s]
  end

  test "a choice with two questions asks them one after the other, skipping one with nothing to pick" do
    lands(Magic::Cards::Forest, 3)
    land = Magic::Cards::Forest.new(game: @game, owner: @player)
    elf = Magic::Cards::ElvishMystic.new(game: @game, owner: @player)
    [elf, land].each { |card| @player.library.add(card) }
    spell = Magic::Cards::BountyOfSkemfar.new(game: @game, owner: @player)
    @player.hand.add(spell)

    assert_nil @table.cast(@uid, @player.hand.cards.index(spell))
    assert_equal "pick", choice[:kind]
    assert_match(/Land/, choice[:prompt])
    assert_includes ids(choice[:cards]), land.object_id.to_s
    assert_nil @table.choose(@uid, [land.object_id.to_s])

    assert_match(/Elf/, choice[:prompt])
    assert_equal [elf.object_id.to_s], ids(choice[:cards])
    assert_nil @table.choose(@uid, [elf.object_id.to_s])

    assert_nil choice
    assert_includes @player.hand.cards, elf
    assert_includes @game.battlefield.permanents.map(&:card), land
  end

  test "an X spell asks for X, then for that many targets, and pays X" do
    lands(Magic::Cards::Forest, 3)
    first = put(Magic::Cards::LlanowarElves)
    second = put(Magic::Cards::ElvishMystic)
    thrive = Magic::Cards::Thrive.new(game: @game, owner: @player)
    @player.hand.add(thrive)

    assert @table.view_for(@uid)[:you][:hand].find { |c| c[:name] == "Thrive" }[:castable]
    assert_nil @table.cast(@uid, @player.hand.cards.index(thrive))
    assert_equal "options", choice[:kind]
    # Three Forests and two mana elves make five mana: X up to 4 and the {G}.
    assert_equal %w[0 1 2 3 4], ids(choice[:options])
    assert choice[:cancelable]

    assert_nil @table.choose(@uid, "2")
    assert_match(/1 of 2/, choice[:prompt])
    assert_equal 0, @player.permanents.count(&:tapped?), "nothing is paid until every target is chosen"
    assert_nil @table.choose(@uid, first.object_id.to_s)
    assert_match(/2 of 2/, choice[:prompt])
    assert_not_includes ids(choice[:targets]), first.object_id.to_s, "different creatures"
    assert_nil @table.choose(@uid, second.object_id.to_s)

    assert_equal 2, first.power, "a +1/+1 counter on a 1/1"
    assert_equal 2, second.power
    assert_equal 3, @player.permanents.count(&:tapped?), "X of 2 and the {G}"
  end

  test "an additional cost that sacrifices a creature asks which one, and the spell is not offered without one" do
    put(Magic::Cards::Swamp)
    rites = Magic::Cards::VillageRites.new(game: @game, owner: @player)
    @player.hand.add(rites)
    index = @player.hand.cards.index(rites)

    assert_not @table.view_for(@uid)[:you][:hand][index][:castable], "nothing to sacrifice"
    assert_match(/sacrifice/, @table.cast(@uid, index))

    elf = put(Magic::Cards::LlanowarElves)
    assert @table.view_for(@uid)[:you][:hand][index][:castable]
    assert_nil @table.cast(@uid, index)
    assert_equal "pick", choice[:kind]
    assert_equal [1, 1], choice.values_at(:min, :max)
    assert_equal [elf.object_id.to_s], ids(choice[:cards])
    assert_nil @table.choose(@uid, "cancel")
    assert_includes @game.battlefield.permanents, elf

    hand = @player.hand.count
    assert_nil @table.cast(@uid, index)
    assert_nil @table.choose(@uid, [elf.object_id.to_s])
    assert_not_includes @game.battlefield.permanents, elf
    assert_equal hand - 1 + 2, @player.hand.count, "the spell left the hand and two cards were drawn"
  end

  test "a kicker paid with mana is offered, and paying it adds to what is tapped" do
    lands(Magic::Cards::Forest, 8)
    bears = put(Magic::Cards::GrizzlyBears)
    surge = Magic::Cards::VastwoodSurge.new(game: @game, owner: @player)
    @player.hand.add(surge)

    assert_nil @table.cast(@uid, @player.hand.cards.index(surge))
    assert_equal %w[no yes], ids(choice[:options])
    assert_nil @table.choose(@uid, "yes")
    assert_equal "pick", choice[:kind], "the search for lands comes next"
    assert_equal 8, @player.permanents.count(&:tapped?), "four for the spell and four for the kicker"

    assert_nil @table.choose(@uid, [])
    assert_equal 4, bears.power, "two +1/+1 counters, because it was kicked"
  end

  test "an unkicked spell taps only its own cost" do
    lands(Magic::Cards::Forest, 8)
    surge = Magic::Cards::VastwoodSurge.new(game: @game, owner: @player)
    @player.hand.add(surge)

    assert_nil @table.cast(@uid, @player.hand.cards.index(surge))
    assert_nil @table.choose(@uid, "no")
    assert_equal 4, @player.permanents.count(&:tapped?)
  end

  test "a card in your graveyard with an ability usable from there can use it" do
    lands(Magic::Cards::Forest, 3)
    crown = Magic::Cards::CrownOfSkemfar.new(game: @game, owner: @player)
    @player.graveyard.add(crown)

    entry = @table.view_for(@uid)[:you][:graveyard_abilities].first
    assert_equal "Crown of Skemfar", entry[:name]
    assert entry[:abilities].first[:activatable]
    assert_nil @table.activate_from_graveyard(@uid, entry[:id], 0)

    assert_includes @player.hand.cards, crown
    assert_equal 3, @player.permanents.count(&:tapped?)
  end

  test "an ability from the graveyard is not offered without the mana for it" do
    crown = Magic::Cards::CrownOfSkemfar.new(game: @game, owner: @player)
    @player.graveyard.add(crown)

    assert_not @table.view_for(@uid)[:you][:graveyard_abilities].first[:abilities].first[:activatable]
    assert_match(/can't be activated/, @table.activate_from_graveyard(@uid, crown.object_id, 0))
  end

  test "a choice's own prompt is prefixed with the card it came from" do
    composer = put(Magic::Cards::ComposerOfSpring)
    @game.choices.add(Magic::Cards::ComposerOfSpring::LandChoice.new(actor: composer))

    assert_equal "Composer of Spring: Put a land card from your hand onto the battlefield tapped?", choice[:prompt]
  end

  test "'you may pay {G}' taps a land for the payment" do
    visionary = put(Magic::Cards::LeafCrownedVisionary)
    forest = put(Magic::Cards::Forest)
    @game.choices.add(Magic::Cards::LeafCrownedVisionary::MayPayChoice.new(actor: visionary))
    hand = @player.hand.count

    assert_equal "may", choice[:kind]
    assert_nil @table.choose(@uid, "yes")

    assert forest.tapped?
    assert_equal hand + 1, @player.hand.count
  end

  test "casting an Elf pays generic with off-colour lands, leaving a Forest open for Leaf-Crowned Visionary" do
    put(Magic::Cards::LeafCrownedVisionary)
    2.times { put(Magic::Cards::Island) }
    4.times { put(Magic::Cards::Forest) }
    spell = Magic::Cards::SylvanMessenger.new(game: @game, owner: @player)
    @player.hand.add(spell)

    assert_nil @table.cast(@uid, @player.hand.cards.index(spell))

    assert_equal "may", choice[:kind]
    assert_match(/Pay \{G\}/, choice[:prompt])
  end

  test "'you may pay {X}{X}' asks for X, pays it, and asks how to distribute the counters" do
    numa = put(Magic::Cards::NumaJoragaChieftain)
    other = put(Magic::Cards::LlanowarElves)
    lands(Magic::Cards::Forest, 5)
    @game.choices.add(Magic::Cards::NumaJoragaChieftain::MayPayChoice.new(actor: numa))

    assert_equal %w[0 1 2 3], ids(choice[:options]), "five Forests and a mana elf make six mana: X of 3 at most"
    assert_nil @table.choose(@uid, "2")
    assert_equal 4, @player.permanents.count(&:tapped?)

    assert_equal "assign", choice[:kind]
    assert_equal 2, choice[:total]
    assert_match(/distribute 2/i, choice[:prompt])
    assert_match(/Distribute all 2/, @table.choose(@uid, { numa.object_id.to_s => 1 }))
    assert_nil @table.choose(@uid, { numa.object_id.to_s => 1, other.object_id.to_s => 1 })

    assert_equal 3, numa.power
    assert_equal 2, other.power
  end

  test "declining to pay X pays nothing" do
    numa = put(Magic::Cards::NumaJoragaChieftain)
    lands(Magic::Cards::Forest, 2)
    @game.choices.add(Magic::Cards::NumaJoragaChieftain::MayPayChoice.new(actor: numa))

    assert_nil @table.choose(@uid, "0")
    assert_equal 0, @player.permanents.count(&:tapped?)
    assert_nil choice
  end

  test "a creature type is chosen from the types in play" do
    put(Magic::Cards::LlanowarElves, @opponent)
    put(Magic::Cards::GrizzlyBears, @opponent)
    pact = Magic::Cards::PactOfTheSerpent.new(game: @game, owner: @player)
    @game.choices.add(Magic::Cards::PactOfTheSerpent::TypeChoice.new(actor: pact, target: @opponent))

    assert_equal "options", choice[:kind]
    assert_includes ids(choice[:options]), "Elf"
    assert_match(/Not a valid/, @table.choose(@uid, "Spaghetti"))

    life = @opponent.life
    assert_nil @table.choose(@uid, "Elf")
    assert_equal life - 1, @opponent.life
  end

  test "a colour choice offers only the colours it allows" do
    grove = put(Magic::Cards::ThrivingGrove)
    @game.choices.add(Magic::Cards::ThrivingGrove::ColorChoice.new(actor: grove))

    assert_equal %w[white blue black red], ids(choice[:options])
    assert_nil @table.choose(@uid, "black")
  end

  test "an ability that taps other creatures asks which, and the source is not among them for Lathril" do
    lathril = put(Magic::Cards::LathrilBladeOfTheElves)
    tokens = Array.new(10) { Magic::Cards::LathrilBladeOfTheElves::ElfWarriorToken.new(game: @game, owner: @player).resolve!(enters_tapped: false) }
    tokens.each { |token| token.controlled_since_turn = 0 }

    view = @table.view_for(@uid)[:you][:battlefield].find { |p| p[:id] == lathril.object_id }
    assert view[:abilities].first[:activatable]
    assert_nil @table.activate(@uid, lathril.object_id, 0)
    assert_equal [10, 10], choice.values_at(:min, :max)
    assert_not_includes ids(choice[:cards]), lathril.object_id.to_s

    life = @opponent.life
    assert_nil @table.choose(@uid, ids(choice[:cards]))
    assert_equal life - 10, @opponent.life
  end

  test "a gift is promised or not as the spell is cast, and the opponent draws only when it is" do
    lands(Magic::Cards::Plains, 5)
    put(Magic::Cards::GrizzlyBears, @opponent)
    starfall = Magic::Cards::StarfallInvocation.new(game: @game, owner: @player)
    @player.hand.add(starfall)

    assert_nil @table.cast(@uid, @player.hand.cards.index(starfall))
    assert_equal %w[no yes], ids(choice[:options])
    opponent_hand = @opponent.hand.count
    assert_nil @table.choose(@uid, "yes")

    assert_equal opponent_hand + 1, @opponent.hand.count
    assert_equal 5, @player.permanents.count(&:tapped?)
  end

  test "declining the gift gives the opponent nothing" do
    lands(Magic::Cards::Plains, 5)
    starfall = Magic::Cards::StarfallInvocation.new(game: @game, owner: @player)
    @player.hand.add(starfall)

    assert_nil @table.cast(@uid, @player.hand.cards.index(starfall))
    opponent_hand = @opponent.hand.count
    assert_nil @table.choose(@uid, "no")

    assert_equal opponent_hand, @opponent.hand.count
  end

  test "'you may discard up to two cards' asks for up to two and draws that many" do
    fable = put(Magic::Cards::FableOfTheMirrorBreaker)
    @game.choices.add(Magic::Cards::FableOfTheMirrorBreaker::DiscardUpToTwo.new(actor: fable))
    discards = @player.hand.cards.first(2)

    assert_equal "pick", choice[:kind]
    assert_equal [0, 2], choice.values_at(:min, :max)
    assert_nil @table.choose(@uid, discards.map { |card| card.object_id.to_s })

    assert_equal 2, (discards & @player.graveyard.cards.to_a).size
  end

  test "declining to discard changes nothing" do
    fable = put(Magic::Cards::FableOfTheMirrorBreaker)
    @game.choices.add(Magic::Cards::FableOfTheMirrorBreaker::DiscardUpToTwo.new(actor: fable))
    hand = @player.hand.count

    assert_nil @table.choose(@uid, [])
    assert_equal hand, @player.hand.count
  end

  test "The Gitrog Monster's upkeep asks which land to sacrifice, and the pick is the one sacrificed" do
    gitrog = put(Magic::Cards::TheGitrogMonster)
    forest, island = put(Magic::Cards::Forest), put(Magic::Cards::Island)
    @game.choices.add(Magic::Cards::TheGitrogMonster::SacrificeLandChoice.new(actor: gitrog))

    assert_equal "pick", choice[:kind]
    assert_equal [0, 1], choice.values_at(:min, :max)
    assert_equal [forest, island].map { ChoicePrompt.target_id(_1) }.sort, ids(choice[:cards]).sort
    assert_nil @table.choose(@uid, [ChoicePrompt.target_id(island)])

    assert_includes @player.permanents, gitrog
    assert_includes @player.permanents, forest
    refute_includes @player.permanents, island
  end

  test "picking no land for The Gitrog Monster sacrifices it" do
    gitrog = put(Magic::Cards::TheGitrogMonster)
    forest = put(Magic::Cards::Forest)
    @game.choices.add(Magic::Cards::TheGitrogMonster::SacrificeLandChoice.new(actor: gitrog))

    assert_nil @table.choose(@uid, [])

    refute_includes @player.permanents, gitrog
    assert_includes @player.permanents, forest
  end

  test "X for a spell that targets a creature with mana value X only offers the X that has one" do
    lands(Magic::Cards::Island, 6)
    put(Magic::Cards::GrizzlyBears, @opponent) # mana value 2
    fae = Magic::Cards::StolenByTheFae.new(game: @game, owner: @player)
    @player.hand.add(fae)

    assert_nil @table.cast(@uid, @player.hand.cards.index(fae))
    assert_equal ["2"], ids(choice[:options])
  end

  test "mana that can only be spent on some spells does not pay for a choice" do
    path = put(Magic::Cards::PathOfAncestry)
    path.untap! # it enters tapped
    remora = put(Magic::Cards::MysticRemora)
    @game.choices.add(Magic::Cards::MysticRemora::UpkeepChoice.new(actor: remora))
    remora.add_counter("age", amount: 1)

    # Only Path of Ancestry to pay with, and its mana is restricted: the upkeep can't be paid, so the Remora goes.
    @table.send(:dismiss_empty_choices!)
    assert_not_includes @player.permanents, remora
    assert_not path.tapped?, "its restricted mana was not spent on the upkeep"
  end

  test "a double-faced land is played as its back face" do
    pathway = Magic::Cards::NeedlevergePathway.new(game: @game, owner: @player)
    @player.hand.add(pathway)

    @table.play_land(@uid, @player.hand.cards.index(pathway), "hand", "back")

    assert_equal ["Pillarverge Pathway"], @player.permanents.map(&:name)
  end
end
