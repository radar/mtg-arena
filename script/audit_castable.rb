Deck.load(ENV.fetch("DECK", Table::DECK)).entries.each do |e|
  next unless e.card_class
  t = Table.new("c", deck: Deck.new("x", "40 Forest (X) 1\n")); t.join("a"); t.join("b")
  2.times { t.seats.each { |s| t.choose(s.uid, "keep") if t.view_for(s.uid).dig(:choice, :chooser) } }
  g = t.game; pl = g.current_turn.active_player
  uid = t.seats.find { _1.player == pl }.uid
  %w[Plains Plains Plains Swamp Swamp Swamp Forest Forest Forest Forest Forest Forest Island Island Island Island Mountain Mountain Mountain Mountain].each do |n|
    Magic::Permanent.resolve_spell(game: g, card: Magic::Cards.const_get(n).new(game: g, owner: pl)).tap { |pm| pm.controlled_since_turn = 0; pm.untap! }
  end
  # a creature to target
  Magic::Permanent.resolve_spell(game: g, card: Magic::Cards::LlanowarElves.new(game: g, owner: pl))
  card = e.card_class.new(game: g, owner: pl)
  next if card.land?
  pl.hand.add(card)
  # A double-faced card is listed "Front / Back" but is named for its front face.
  view = t.view_for(uid)[:you][:hand].find { |c| c[:name] == card.name }
  action = Magic::Actions::Cast.new(game: g, player: pl, card: card)
  reason = if view[:castable] then nil
           elsif !t.send(:targets_available?, pl, card, action) then "no legal target or mode"
           elsif action.illegal_reason then "illegal: #{action.illegal_reason}"
           else "unaffordable/other" end
  puts "#{e.name}: #{reason || 'castable'}" if reason
end
