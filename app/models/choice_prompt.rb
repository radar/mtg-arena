# Presents one pending Magic::Choice to its controller and turns their answer into the arguments the engine's
# `resolve!` expects. Each kind of choice the engine can raise needs a branch in #view and #resolve.
#
# View kinds (what the client renders):
#   may     yes/no buttons
#   target  click a player or permanent on the board
#   pick    choose up to `max` cards from a list shown as a card picker
#   options pick one of several labelled options
#   confirm just acknowledge
#   sort    put each listed card in one of two destinations (scry: top/bottom, surveil: top/graveyard)
class ChoicePrompt
  class Unsupported < StandardError; end

  COLORS = %i[white blue black red green].freeze

  attr_reader :choice, :game

  # +partial+ holds the answers given so far to a choice that asks several questions (Bounty of Skemfar's land, then Elf);
  # it belongs to the Table, since the prompt is rebuilt each time the choice is looked at. +payer+ pays mana for a choice
  # that wants it (see #resolve).
  def initialize(choice, game, partial: {}, payer: nil)
    @choice = choice
    @game = game
    @partial = partial
    @payer = payer
  end

  # The player who must answer.
  def controller
    # Some choices belong to a player other than the card's controller (an opponent sacrificing to The Eldest Reborn).
    player = choice.player if choice.respond_to?(:player)
    player || choice.controller
  end

  def view
    base = { prompt: prompt }
    case choice
    when Magic::Choice::OrderTriggers then base.merge(kind: "may", auto: true)
    when Magic::Choice::May then may_view(base)
    when Magic::Choice::Targeted then targeted_view(base)
    when Magic::Choice::Scry then base.merge(kind: "sort", cards: card_views(choice.choices), destinations: %w[top bottom])
    when Magic::Choice::Surveil then base.merge(kind: "sort", cards: card_views(choice.choices), destinations: %w[top graveyard])
    when Magic::Choice::Discard then base.merge(kind: "pick", min: 1, max: choice.amount, cards: card_views(choice.cards.to_a))
    when Magic::Choice::SearchLibrary then base.merge(kind: "pick", min: 0, max: choice.upto, cards: card_views(choice.choices.to_a))
    when Magic::Choice::LookAtTopCards, Magic::Choice::ReturnFromAmong
      base.merge(kind: "pick", min: 0, max: 1, cards: card_views(choice.choices.to_a))
    else generic_view(base)
    end
  end

  # A choice with nothing to choose from (no legal targets, no cards to pick or sort) has no panel worth showing, so
  # the game drops it, the way an ability with no legal target never goes on the stack.
  def nothing_to_choose?
    return false if auto_resolve?
    # "You may pay {G}" with no mana for it: there is only one thing to do.
    return true if unaffordable_payment?

    options = view
    case options[:kind]
    when "target" then options[:targets].empty?
    when "pick", "sort" then options[:cards].empty?
    else false
    end
  rescue Unsupported
    false
  end

  # The card the choice came from, for the log.
  def source_name
    choice.actor.name if choice.respond_to?(:actor) && choice.actor.respond_to?(:name)
  end

  # Answers the choice. Raises with a message for the player when the answer is not valid.
  def resolve(answer)
    case choice
    when Magic::Choice::OrderTriggers then game.resolve_choice!(target: choice.choices.first)
    when Magic::Choice::May then resolve_may(answer)
    when Magic::Choice::Targeted then game.resolve_choice!(target: find(choice.choices, Array(answer).first))
    when Magic::Choice::Scry
      sorted = sorted_cards(answer, "top", "bottom")
      game.resolve_choice!(top: sorted["top"], bottom: sorted["bottom"])
    when Magic::Choice::Surveil
      sorted = sorted_cards(answer, "top", "graveyard")
      game.resolve_choice!(top: sorted["top"], graveyard: sorted["graveyard"])
    when Magic::Choice::Discard then game.resolve_choice!(cards: Array(answer).map { |id| find(choice.cards.to_a, id) })
    when Magic::Choice::SearchLibrary then game.resolve_choice!(targets: Array(answer).map { |id| find(choice.choices.to_a, id) })
    when Magic::Choice::LookAtTopCards, Magic::Choice::ReturnFromAmong
      id = Array(answer).first
      game.resolve_choice!(target: id ? find(choice.choices.to_a, id) : nil)
    else generic_resolve(answer)
    end
  end

  # A choice that asks several questions, all of which have been answered or have nothing to choose from, can be resolved
  # without asking the player anything more.
  def auto_resolve?
    !sequential_keys.nil? && pending_key.nil?
  end

  def self.target_id(target)
    target.is_a?(Magic::Player) ? target.name : target.object_id.to_s
  end

  private

  def prompt
    return choice.prompt if choice.respond_to?(:prompt) && choice.prompt

    source = choice.respond_to?(:actor) && choice.actor ? "#{choice.actor.name}: " : ""
    "#{source}#{choice.class.name.demodulize.titleize}"
  end

  # Cards define their own Choice subclasses with their own `resolve!` signatures. Without a branch above, read the
  # signature: `target:` takes one of `choices`, `targets:` takes several, and no arguments is a plain acknowledgement.
  def generic_view(base)
    keys = resolve_keywords
    if sequential_keys
      key = pending_key
      base.merge(kind: "pick", min: 0, max: 1, cards: card_views(question_choices(key)),
                 prompt: "#{prompt} (#{key.to_s.titleize}, if any)")
    elsif keys == [:color]
      base.merge(kind: "options", options: allowed_colors.map { |color| { id: color.to_s, label: color.to_s.capitalize } })
    elsif keys == [:creature_type]
      base.merge(kind: "options", options: creature_type_options.map { |type| { id: type, label: type } })
    elsif keys == [:distribution] && choice.respond_to?(:amount)
      # "Distribute N counters among any number of targets": a number for each, adding up to N.
      rows = choice.choices.to_a.each_with_index.map do |target, index|
        { id: self.class.target_id(target), label: target_label(target), lethal: 0, value: index.zero? ? choice.amount : 0 }
      end
      base.merge(kind: "assign", total: choice.amount, rows: rows)
    elsif keys == [:mode] && choice.respond_to?(:modes) && choice.modes.any?
      base.merge(kind: "options", options: choice.modes.map { |id, label| { id: id.to_s, label: label } })
    elsif keys.include?(:target) && choice.respond_to?(:choices)
      targeted_view(base, min: required?(:target) ? 1 : 0)
    elsif keys.include?(:targets) && choice.respond_to?(:choices)
      limit = choice.respond_to?(:upto) ? choice.upto : choice.choices.to_a.size
      base.merge(kind: "pick", min: required?(:targets) ? 1 : 0, max: limit, cards: card_views(choice.choices.to_a))
    elsif keys.empty?
      base.merge(kind: "confirm")
    else
      raise Unsupported, "#{choice.class.name} (resolve!(#{keys.join(', ')})) is not supported yet"
    end
  end

  def generic_resolve(answer)
    keys = resolve_keywords
    if sequential_keys
      answer_question(Array(answer).first)
    elsif keys == [:color]
      color = allowed_colors.find { |c| c.to_s == answer.to_s } || raise("Not a valid choice.")
      game.resolve_choice!(color: color)
    elsif keys == [:creature_type]
      type = creature_type_options.find { |t| t == answer.to_s } || raise("Not a valid choice.")
      game.resolve_choice!(creature_type: type)
    elsif keys == [:distribution] && choice.respond_to?(:amount)
      amounts = answer.to_h.stringify_keys.transform_values(&:to_i)
      raise "Distribute all #{choice.amount} (you distributed #{amounts.values.sum})." unless amounts.values.sum == choice.amount

      distribution = amounts.reject { |_, n| n.zero? }.to_h { |id, n| [find(choice.choices.to_a, id), n] }
      game.resolve_choice!(distribution: distribution)
    elsif keys == [:mode] && choice.respond_to?(:modes) && choice.modes.any?
      mode = choice.modes.keys.find { |key| key.to_s == answer.to_s } || raise("Not a valid choice.")
      game.resolve_choice!(mode: mode)
    elsif keys.include?(:target) && choice.respond_to?(:choices)
      id = Array(answer).first
      game.resolve_choice!(target: id ? find(choice.choices.to_a, id) : nil)
    elsif keys.include?(:targets) && choice.respond_to?(:choices)
      game.resolve_choice!(targets: Array(answer).map { |id| find(choice.choices.to_a, id) })
    elsif keys.empty?
      game.resolve_choice!
    else
      raise Unsupported, "#{choice.class.name} (resolve!(#{keys.join(', ')})) is not supported yet"
    end
  end

  # "You may return target card ...": a May whose `resolve!` also wants a target. Picking nothing declines.
  def may_with_target?
    resolve_keywords.include?(:target) && choice.respond_to?(:choices)
  end

  # "You may pay {X}{X}" (a May whose `resolve!` takes `x:`): the player picks X, and 0 declines.
  def may_with_x?
    resolve_keywords.include?(:x) && choice.respond_to?(:payment_cost)
  end

  # "You may discard up to two cards" (Fable of the Mirror-Breaker): a May whose `resolve!` takes `cards:`. Picking none
  # declines.
  def may_with_cards?
    resolve_keywords.include?(:cards) && choice.respond_to?(:choices)
  end

  def may_view(base)
    if may_with_cards?
      cards = choice.choices.to_a
      top = choice.respond_to?(:upto) ? choice.upto : cards.size
      base.merge(kind: "pick", min: 0, max: [top, cards.size].min, cards: card_views(cards))
    elsif may_with_x?
      top = @payer ? @payer.max_x(choice) : 0
      base.merge(kind: "options", options: (0..top).map { |x| { id: x.to_s, label: x.zero? ? "Don't pay" : "X = #{x}" } })
    elsif may_with_target?
      base.merge(kind: "pick", min: 0, max: 1, cards: card_views(choice.choices.to_a))
    else
      base.merge(kind: "may")
    end
  end

  def resolve_may(answer)
    if may_with_cards?
      ids = Array(answer)
      return game.skip_choice! if ids.empty?

      return game.resolve_choice!(cards: ids.map { |id| find(choice.choices.to_a, id) })
    end
    if may_with_x?
      x = answer.to_i
      return game.skip_choice! if x <= 0

      return game.resolve_choice!(x: x, payment: pay(choice.payment_cost(x)))
    end
    if may_with_target?
      id = Array(answer).first
      return id ? game.resolve_choice!(target: find(choice.choices.to_a, id)) : game.skip_choice!
    end
    return game.skip_choice! unless answer.to_s == "yes"

    # "You may pay {G}. If you do, ...": the mana comes from the player's lands.
    if resolve_keywords.include?(:payment) && choice.respond_to?(:payment_cost)
      game.resolve_choice!(payment: pay(choice.payment_cost))
    else
      game.resolve_choice!
    end
  end

  # A May that wants mana paid, when the player's lands can't pay for even the least it takes.
  def unaffordable_payment?
    return false unless @payer && choice.is_a?(Magic::Choice::May) && choice.respond_to?(:payment_cost)

    if may_with_x?
      @payer.max_x(choice).zero?
    elsif resolve_keywords.include?(:payment)
      !@payer.payable?(choice, choice.payment_cost)
    else
      false
    end
  end

  def pay(cost)
    raise "Nothing to pay with." unless @payer

    @payer.pay(choice, cost)
  end

  def resolve_keywords
    choice.method(:resolve!).parameters.filter_map { |type, name| name if %i[key keyreq].include?(type) }
  end

  # A choice whose `resolve!` takes several keywords, each with a `<keyword>_choices` list (Bounty of Skemfar's `land:` and
  # `elf:`), is asked one question per keyword. Nil for any other choice.
  def sequential_keys
    # The table's own prompts (CastPrompt and the like) wrap a bare struct, not an engine choice.
    return unless choice.respond_to?(:resolve!)

    keys = resolve_keywords
    keys if keys.size > 1 && keys.all? { |key| choice.respond_to?("#{key}_choices") }
  end

  # The next keyword to ask about: not answered yet, and with something to pick.
  def pending_key
    sequential_keys.find { |key| !@partial.key?(key) && question_choices(key).any? }
  end

  def question_choices(key)
    choice.public_send("#{key}_choices").to_a
  end

  # Records the answer to the current question; once none are left, resolves the choice with all the answers.
  def answer_question(id)
    key = pending_key
    @partial[key] = id ? find(question_choices(key), id) : nil
    return if pending_key

    answers = sequential_keys.to_h { |k| [k, @partial[k]] }
    @partial.clear
    game.resolve_choice!(**answers)
  end

  # The colours a colour choice allows: its own list (a Thriving land: any but its own) or all five.
  def allowed_colors
    own = choice.class.const_defined?(:COLORS, false) ? choice.class::COLORS : nil
    own || COLORS
  end

  # Creature types worth naming: those of creatures in play and of the creature cards in the controller's hand and
  # graveyard, so the usual answer is a click away. (The engine accepts any type; a list of every type would be too long.)
  def creature_type_options
    pool = game.battlefield.creatures.to_a + controller.hand.cards.select(&:creature?) + controller.graveyard.cards.select(&:creature?)
    types = pool.flat_map { |card| card.types.select { |type| Magic::Types::Creatures.values.include?(type) } }
    types.uniq.sort.presence || %w[Human Elf Goblin Zombie]
  end

  def required?(keyword)
    choice.method(:resolve!).parameters.include?([:keyreq, keyword])
  end

  # Players and permanents are clicked on the board; anything else (cards in a zone) is picked from a list.
  def targeted_view(base, min: 1)
    options = choice.choices.to_a
    if options.all? { |t| t.is_a?(Magic::Player) || (t.is_a?(Magic::Permanent) && !t.card.land?) }
      base.merge(kind: "target", targets: options.map { |t| { id: self.class.target_id(t), label: target_label(t) } })
    else
      base.merge(kind: "pick", min: min, max: 1, cards: card_views(options))
    end
  end

  def target_label(target)
    target.is_a?(Magic::Player) ? target.name : "#{target.name} (#{target.controller.name})"
  end

  def card_views(cards)
    cards.map do |card|
      graveyard_of = card.zone&.graveyard? && card.owner.respond_to?(:name) ? card.owner.name : nil
      { id: self.class.target_id(card), name: card.name, graveyard_of: graveyard_of }
    end
  end

  def find(options, id)
    options.find { |option| self.class.target_id(option) == id.to_s } || raise("Not a valid choice.")
  end

  def sorted_cards(answer, *destinations)
    answer = answer.to_h.stringify_keys
    destinations.index_with { |destination| Array(answer[destination]).map { |id| find(choice.choices.to_a, id) } }
  end
end
