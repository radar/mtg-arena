t = Table.new("a", deck: Deck.new("x", "40 Forest (X) 1\n")); t.join("a"); t.join("b")
g = t.game; pl = g.players.first
Deck.load(ENV.fetch("DECK", Table::DECK)).entries.each do |e|
  next unless e.card_class
  klass = e.card_class
  f = []
  begin
    card = klass.new(game: g, owner: pl)
    m = klass.instance_methods
    f << "TARGET(spell)" if m.include?(:target_choices)
    f << "MULTI-TARGET" if m.include?(:multi_target?)
    f << "modes#{klass::MODES.size}" if klass::MODES.any?
    f << "MODE-TARGETS" if klass::MODES.any? { |mc| mc.method_defined?(:target_choices) }
    cost = card.cost.cost
    f << "X-COST" if cost.key?(:x)
    f << "kicker" if card.kicker_cost.respond_to?(:cost) && card.kicker_cost.cost.any? rescue nil
    %i[alternative_cost flashback_cost cycling_cost adventure_cost evoke_cost blitz_cost].each do |meth|
      v = (card.public_send(meth) rescue nil)
      f << meth.to_s.sub("_cost", "").upcase if v && !(v.respond_to?(:zero?) && v.zero? && false)
    end
    f << "extra-costs" if card.respond_to?(:additional_costs) && card.additional_costs.any?
    f << "instant/flash" if card.instant? || card.flash?
    f << "AURA" if klass.ancestors.include?(Magic::Cards::Aura)
    f << "equipment" if klass.ancestors.include?(Magic::Cards::Equipment)
    f << "saga" if klass.ancestors.include?(Magic::Cards::Saga)
    f << "planeswalker" if card.respond_to?(:planeswalker?) && card.planeswalker?
    f << "creature" if card.creature?
    # permanent-level things
    perm = (Magic::Permanent.resolve(game: g, card: card) rescue nil)
    if perm
      perm.controlled_since_turn = 0
      abilities = perm.activated_abilities.reject { |a| a.is_a?(Magic::ManaAbility) }
      abilities.each do |a|
        costs = a.costs.map { |c| c.class.name.demodulize }
        supported = (Table::SELF_COSTS + Table::PICK_COSTS).flat_map { |kind| [kind, *kind.subclasses] }.map { |kind| kind.name.demodulize }
        unsup = costs - supported
        tgt = a.respond_to?(:target_choices)
        f << "ability[#{costs.join('+')}#{tgt ? ' +TARGET' : ''}#{unsup.any? ? ' UNSUPPORTED-COST' : ''}]"
      end
      f << "loyalty-abilities" if card.planeswalker?
      f << "statics:#{perm.card.static_abilities.map { |s| s.name.demodulize }.join('/')}" if perm.card.respond_to?(:static_abilities) && perm.card.static_abilities.any?
      f << "ETB" if perm.card.etb_triggers.any?
      f << "events:#{perm.card.event_handlers.keys.map { |k| k.name.demodulize }.join('/')}" if perm.card.event_handlers.any?
      f << "ltb" if perm.card.ltb_triggers.any? rescue nil
      f << "death" if perm.card.death_triggers.any? rescue nil
      f << "combat/turn-triggers" if perm.card.respond_to?(:turn_triggers) && false
    end
    klass.constants(false).each do |c|
      v = klass.const_get(c)
      next unless v.is_a?(Class) && v < Magic::Choice
      params = v.instance_method(:resolve!).parameters.map { |ty, n| "#{ty == :keyreq ? '' : '?'}#{n}" }
      base = v.ancestors[1..].find { |a| a.name&.start_with?("Magic::Choice") }&.name&.demodulize || "Choice"
      f << "choice:#{c}[#{base}](#{params.join(',')})"
    end
  rescue StandardError => ex
    f << "ANALYZE-ERROR #{ex.class}: #{ex.message[0, 60]}"
  end
  puts "#{e.name} (#{e.count}): #{f.join(' ; ')}"
end
