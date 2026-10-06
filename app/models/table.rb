# One Magic game room. Lives in memory (see TableRegistry); wraps a Magic::Game once two players have joined.
class Table
  SEATS = 2
  DECK = "enchantress".freeze

  STEPS = %w[beginning untap upkeep draw first_main beginning_of_combat declare_attackers declare_blockers combat_damage end_of_combat second_main end cleanup].freeze

  # Steps where the active player always has a decision. Combat steps stop too, but only when there is something to
  # attack or block with (see #stop_here?). Every other step is passed through automatically.
  STOP_STEPS = %w[first_main second_main].freeze
  MAX_AUTO_STEPS = 30

  CHOICE_PENDING = "Resolve the pending choice first.".freeze
  RESPOND_FIRST = "Respond to what is on the stack, or pass, first.".freeze

  # Costs a permanent's own ability may have for us to pay it automatically: tap, sacrifice or exile itself, mana, or
  # removing counters from itself.
  # Costs the player pays by picking cards or permanents (see CostPrompt).
  PICK_COSTS = [Magic::Costs::Sacrifice, Magic::Costs::Discard, Magic::Costs::MultiTap].freeze
  SELF_COSTS = [Magic::Costs::SelfTap, Magic::Costs::SelfSacrifice, Magic::Costs::SelfExile, Magic::Costs::Mana, Magic::Costs::RemoveCounter,
                Magic::Costs::PayLife].freeze

  Seat = Struct.new(:uid, :name, :player, :deck, keyword_init: true)

  attr_reader :id, :seats, :game, :log

  # Wraps each player action to record it, and to seed its shuffles (see Recording).
  prepend Recording

  # +seed+ drives every shuffle and random pick in the game, so the same seed and the same calls replay the same game.
  # +save_records+ is false for a replay, so it does not write a record of its own.
  def initialize(id, deck: Deck.load(DECK), seed: Random.new_seed, save_records: true)
    @id = id
    @deck = deck
    @seed = seed
    @random = Random.new(seed)
    @save_records = save_records
    @calls = []
    @errors = []
    @saved_reasons = Set.new
    @log = EventLog.new
    @seats = []
    @game = nil
    # Reentrant: Recording holds it across a whole action, which takes it again.
    @mutex = Monitor.new
    @pending_activation = nil
    @pending_cast = nil
    @priority = nil
    @passed = []
    @stack_signature = nil
    @pending_mulligan = nil
    @mulligans = {}
    @mulligan_queue = []
    @pending_order = nil
    @conceded = nil
  end

  # Idempotent per uid. Returns the seat, or nil when the table is full. +deck_name+ is the deck the player chose (one of
  # Deck::CHOICES); anything else gets the table's default deck.
  def join(uid, deck_name = nil)
    @mutex.synchronize do
      seat = seats.find { |s| s.uid == uid }
      next seat if seat
      next if seats.size >= SEATS

      deck = Deck::CHOICES.include?(deck_name.to_s) ? Deck.load(deck_name.to_s) : @deck
      seat = Seat.new(uid: uid, name: "Player #{seats.size + 1}", deck: deck)
      seats << seat
      start_game! if seats.size == SEATS
      seat
    end
  end

  # Plays the land at +hand_index+ from +uid+'s hand. Returns nil on success, or the reason it is illegal.
  # +face+ is "back" to play a modal double-faced land (Needleverge Pathway) as its back face.
  def play_land(uid, hand_index, zone = "hand", face = "front")
    @mutex.synchronize do
      seat = seat_for(uid)
      next "You are not in this game." unless seat && started?

      next CHOICE_PENDING if choice_pending?
      next RESPOND_FIRST if @priority

      card = card_in(seat.player, zone, hand_index)
      next "No such card in your #{zone}." unless card
      next "#{card.name} is not a land." unless card.land?

      attempt { seat.player.play_land(land: card, face: face == "back" ? :back : :front) }
    end
  end

  # Casts the spell at +hand_index+, tapping lands for mana automatically. Returns nil on success, or the reason it failed.
  # Spells needing targets or modes are not supported yet.
  def cast(uid, hand_index, zone = "hand")
    @mutex.synchronize do
      seat = seat_for(uid)
      next "You are not in this game." unless seat && started?

      next CHOICE_PENDING if choice_pending?
      next "Wait for #{@priority.name} to respond." if @priority && @priority != seat.player

      player = seat.player
      card = card_in(player, zone, hand_index)
      next "No such card in your #{zone}." unless card
      next "#{card.name} is a land; play it instead." if card.land?

      action = Magic::Actions::Cast.new(game: game, player: player, card: card, value_for_x: x_value(card))
      next action.illegal_reason if action.illegal_reason
      next "#{card.name} needs something to sacrifice." unless sacrifice_costs_payable?(action)
      with_mana = affordable?(player, card)
      with_life = life_payable?(player, card)
      next "Not enough mana to cast #{card.name}." unless with_mana || with_life

      if with_mana && with_life
        @pending_cast = PaymentPrompt.new(game: game, player: player, card: card)
        next nil
      end

      start_cast(player, card, pay_life: !with_mana)
    end
  end

  # Starts casting a spell once it is known how it is paid for; see #advance_cast.
  def start_cast(player, card, pay_life:)
    advance_cast(CastDraft.new(player: player, card: card, pay_life: pay_life))
  end

  # Asks for the next thing a spell still needs (an optional sacrifice cost, its modes, each target), or casts it when
  # nothing is missing. Nothing is paid until then. Returns nil on success or while asking, else the reason it failed.
  def advance_cast(draft)
    player = draft.player
    card = draft.card
    action = Magic::Actions::Cast.new(game: game, player: player, card: card, pay_life: draft.pay_life, value_for_x: x_value(card, draft.x))
    return action.illegal_reason if action.illegal_reason

    if draft.bargain == :ask && (options = bargain_options(player, card)).any?
      @pending_cast = BargainPrompt.new(game: game, draft: draft, choices: options)
      return nil
    end

    if draft.kicker == :ask && mana_kicker?(card)
      if payable?(player, kicked_cost(card, draft))
        @pending_cast = KickerPrompt.new(game: game, draft: draft, cost: card.kicker_cost.cost)
        return nil
      end
      draft.kicker = false
    end

    # "Gift a card": promised for nothing, but the player chooses.
    if draft.kicker == :ask && card.kicker_cost.is_a?(Magic::Costs::Gift)
      @pending_cast = GiftPrompt.new(game: game, draft: draft)
      return nil
    end

    # "As an additional cost to cast this spell, sacrifice a creature": one question per such cost.
    sacrifice_costs(action).each_with_index do |cost, index|
      next if index < draft.sacrifices.size

      @pending_cast = SacrificeCostPrompt.new(game: game, draft: draft, cost: cost, choices: pick_choices(cost))
      return nil
    end

    if draft.x.nil? && card.cost.cost.key?(:x)
      maximum = max_x_for_spell(player, card, draft)
      allowed = (0..maximum).to_a
      # "target creature with mana value X": only the X that leave a legal target.
      if card.respond_to?(:target_fits_x?)
        allowed = allowed.select do |x|
          with_x = Magic::Actions::Cast.new(game: game, player: player, card: card, value_for_x: x)
          target_slots(player, card, with_x, nil, x: x).none? { |slot| slot.choices.empty? }
        end
      end
      return "#{card.name} has no legal target." if allowed.empty?

      @pending_cast = XPrompt.new(game: game, draft: draft, maximum: maximum, allowed: allowed)
      return nil
    end

    if card.modes.any? && draft.modes.nil?
      @pending_cast = CastPrompt.new(game: game, draft: draft)
      return nil
    end

    draft.slots ||= target_slots(player, card, action, draft.modes, x: draft.x)
    return "#{card.name} has no legal target." if draft.slots.any? { |slot| slot.choices.empty? }

    if (slot = draft.next_slot)
      @pending_cast = SpellTargetPrompt.new(game: game, draft: draft, slot: slot)
      return nil
    end

    @pending_cast = nil
    attempt { pay_and_cast(player, build_cast(draft, action), kicker: draft.kicker == true, sacrifices: draft.sacrifices,
                                                                       bargain: (draft.bargain if draft.bargain.is_a?(Magic::Permanent))) }
  end

  # The Cast with everything the draft decided applied to it.
  def build_cast(draft, action)
    draft.modes&.each do |mode_class|
      targets = draft.picks[mode_class]
      action.choose_mode(mode_class) { |mode| mode.targeting(*targets) if targets.any? }
    end
    action.targeting(*draft.picks[:spell]) if draft.picks.key?(:spell)
    action
  end

  # One CastDraft::Slot per target the spell (or each chosen mode of it) needs, with its legal choices.
  def target_slots(player, card, action, modes, x: nil)
    if modes
      modes.flat_map do |mode_class|
        mode = Magic::Actions::Cast::Mode.new(mode_class.new(game: game, card: card), source: card, controller: player)
        next [] unless mode.mode.respond_to?(:target_choices)

        multi = mode.mode.respond_to?(:multi_target?) && mode.mode.multi_target?
        pools = multi ? mode.target_choices : [mode.target_choices]
        distinct = mode.mode.respond_to?(:distinct_targets?) && mode.mode.distinct_targets?
        slots_for(mode_class, pools, distinct) { |target, index| mode.can_target?(target, multi ? index : nil) }
      end
    elsif card.respond_to?(:target_choices)
      multi = card.respond_to?(:multi_target?) && card.multi_target?
      pools = multi ? action.target_choices : [action.target_choices]
      # "X target creatures": X identical pools, one per target (Thrive).
      pools *= card.number_of_targets(x || 1) if card.respond_to?(:number_of_targets) && !multi
      distinct = card.respond_to?(:distinct_targets?) && card.distinct_targets?
      slots_for(:spell, pools, distinct) { |target, index| action.can_target?(target, multi ? index : nil) }
    else
      []
    end
  end

  def slots_for(owner, pools, distinct)
    pools.each_with_index.map do |pool, index|
      CastDraft::Slot.new(owner, index, pool.to_a.select { |target| yield(target, index) }, distinct)
    end
  end

  # What the player could sacrifice for a card's optional sacrifice cost (see Costs::SacrificeKicker); empty when it has none.
  def bargain_options(player, card)
    cost = card.kicker_cost
    cost.respond_to?(:choices_for) ? cost.choices_for(player) : []
  end

  # Could the player cast +card+ by paying life instead of mana (a static ability allows it, and they can afford it)?
  def life_payable?(player, card)
    action = Magic::Actions::Cast.new(game: game, player: player, card: card, pay_life: true, value_for_x: x_value(card))
    action.may_pay_life? && action.pays_life_instead? && action.illegal_reason.nil?
  end

  # Cycles the card at +hand_index+, tapping lands for its cycling cost. Returns nil on success, or the reason it failed.
  def cycle(uid, hand_index)
    @mutex.synchronize do
      seat = seat_for(uid)
      next "You are not in this game." unless seat && started?
      next CHOICE_PENDING if choice_pending?
      next "It is not your turn." unless acting_player == seat.player

      player = seat.player
      card = card_in(player, "hand", hand_index)
      next "No such card in your hand." unless card
      next "#{card.name} can't be cycled." unless card.cycling?
      next "Not enough mana to cycle #{card.name}." unless cyclable?(player, card)

      attempt do
        action = Magic::Actions::Cycle.new(game: game, player: player, card: card)
        tap_for_mana(game, player, action, restricted: false)
        player.cycle(card: card) { |cycle| cycle.mana_cost.auto_pay(player: player) }
        settle!
      end
    end
  end

  # Taps lands for the spell and casts it. +kicker+: the spell is kicked for a mana cost (Vastwood Surge's {4}), which is
  # tapped for together with the rest and paid first.
  def pay_and_cast(player, action, kicker: false, sacrifices: [], bargain: nil)
    # A gift costs nothing: pay for the spell as usual, then promise it.
    gift = kicker && action.card.kicker_cost.is_a?(Magic::Costs::Gift)
    kicker = false if gift
    if kicker
      kicker_hash = action.card.kicker_cost.cost.to_h
      main = action.mana_cost.cost.to_h
      combined = main.merge(kicker_hash) { |_, a, b| a + b }
      # Paid from the pool by hand below, which restricted mana (Path of Ancestry's) isn't part of.
      raise "Not enough mana." unless tap_for_mana(game, player, Struct.new(:mana_cost).new(Magic::Costs::Mana.new(combined)), restricted: false)

      reserve = main.reject { |color, _| %i[generic x].include?(color) }
      flat = payment_from_pool(player, kicker_hash, reserve: reserve)
      # A cost's own `pay` wants the generic part spelled out: { generic: { green: 4 } }, not just { green: 4 }.
      coloured = kicker_hash.reject { |color, _| color == :generic }
      generic = flat.merge(coloured) { |_, amount, used| amount - used }.reject { |_, amount| amount.zero? }
      action.pay_kicker(coloured.merge(generic: generic))
    elsif action.mana_cost.cost[:x].to_i.positive?
      # Lands are tapped for the whole of it, X counted as generic mana.
      whole = action.mana_cost.cost.to_h
      whole = whole.reject { |color, _| color == :x }.merge(generic: whole.fetch(:generic, 0) + whole[:x])
      raise "Not enough mana." unless tap_for_mana(game, player, Struct.new(:mana_cost).new(Magic::Costs::Mana.new(whole)), restricted: false)
    else
      tap_for_mana(game, player, action)
    end
    if action.mana_cost.cost[:x].to_i.positive?
      action.pay_mana(payment_with_x(player, action.mana_cost.cost.to_h))
    else
      action.auto_pay_mana
    end
    # After the lands are tapped: a land sacrificed to Harrow, or a mana creature sacrificed for a kicker, can be tapped for
    # its mana first.
    sacrifices.each { |permanent| action.pay_sacrifice(permanent) }
    action.pay_kicker(bargain) if bargain
    action.pay_kicker(nil) if gift
    game.take_action(action)
    settle!
  end

  # The payment for a cost with {X} in it ({ x: 2, green: 1 }), spelled the way Costs::Mana#pay wants it:
  # { green: 1, x: { green: 2 } }, with any generic part spelled out the same way.
  def payment_with_x(player, cost)
    x = cost.fetch(:x, 0)
    coloured = cost.reject { |color, _| %i[generic x].include?(color) }
    generic = cost.fetch(:generic, 0)
    flat = payment_from_pool(player, coloured.merge(generic: generic + x))
    spare = flat.merge(coloured) { |_, amount, used| amount - used }.reject { |_, amount| amount.zero? }
    x_part = {}
    spare.each do |color, amount|
      take = [amount, x - x_part.values.sum].min
      x_part[color] = take if take.positive?
      spare[color] = amount - [take, 0].max
    end
    payment = coloured.dup
    payment[:x] = x_part
    payment[:generic] = spare.reject { |_, amount| amount.zero? } if generic.positive?
    payment
  end

  # What it takes to give a spell the X it is cast with: a number of {X}.
  def x_value(card, chosen = nil)
    card.cost.cost.key?(:x) ? (chosen || 0) : nil
  end

  # The additional costs of a spell that are paid by sacrificing a permanent ("sacrifice a creature").
  def sacrifice_costs(action)
    action.additional_costs.select { |cost| cost.is_a?(Magic::Costs::Sacrifice) }
  end

  def sacrifice_costs_payable?(action)
    sacrifice_costs(action).all? { |cost| pick_choices(cost).any? }
  end

  # A kicker paid with mana ({4}), as opposed to a sacrifice (see #bargain_options).
  def mana_kicker?(card)
    kicker = card.kicker_cost
    kicker.is_a?(Magic::Costs::Kicker) && kicker.cost.to_h.values.any? { |amount| amount.to_i.positive? }
  end

  # The whole mana cost of a spell with its kicker, as a hash to tap lands for.
  def kicked_cost(card, draft)
    main = card.cost.cost.to_h.merge(generic: card.cost.cost[:generic].to_i + draft.x.to_i) { |_, a, b| b }
    main.delete(:x)
    main.merge(card.kicker_cost.cost.to_h) { |_, a, b| a + b }
  end

  # The largest X (up to ten) the player's lands can pay for, with the kicker if the spell is being kicked.
  def max_x_for_spell(player, card, draft)
    base = card.cost.cost.to_h.reject { |color, _| color == :x }
    base = base.merge(card.kicker_cost.cost.to_h) { |_, a, b| a + b } if draft.kicker == true
    (0..10).take_while { |x| payable?(player, base.merge(generic: base.fetch(:generic, 0) + x)) }.last || 0
  end

  # Finishes (or cancels) a modal spell that was waiting for its modes.
  def choose_cast_modes(prompt, answer)
    if CastPrompt.cancel?(answer)
      @pending_cast = nil
      return nil
    end

    if prompt.is_a?(PaymentPrompt)
      pay_life = prompt.pay_life_for(answer)
      @pending_cast = nil
      return start_cast(prompt.player, prompt.card, pay_life: pay_life)
    end

    draft = prompt.draft
    case prompt
    when BargainPrompt then draft.bargain = prompt.permanent_for(answer)
    when KickerPrompt then draft.kicker = prompt.kicked?(answer)
    when SacrificeCostPrompt then draft.sacrifices << prompt.permanent_for(answer)
    when XPrompt then draft.x = prompt.x_for(answer)
    when CastPrompt then draft.modes = prompt.modes_for(answer)
    when SpellTargetPrompt then draft.pick(prompt.slot, prompt.target_for(answer))
    end
    @pending_cast = nil
    advance_cast(draft)
  rescue StandardError => e
    # An answer that is not valid leaves the question open (nothing was cleared yet).
    e.message
  end

  # Taps one of +uid+'s permanents for mana, adding it to their pool (spells later spend the pool before tapping more
  # lands). +color+ picks among the colours a source can make. Returns nil on success, or the reason it failed.
  def tap_for_mana_by_hand(uid, permanent_id, color = nil)
    @mutex.synchronize do
      seat = seat_for(uid)
      next "You are not in this game." unless seat && started?
      next CHOICE_PENDING if choice_pending?
      next "It is not your turn." unless acting_player == seat.player

      permanent = seat.player.permanents.find { |perm| perm.object_id == permanent_id.to_i }
      source = free_mana_source(seat.player, permanent)
      next "That can't be tapped for mana right now." unless source

      colors = ability_colors(source.ability)
      chosen = colors.find { |c| c.to_s == color.to_s } || colors.first
      before = seat.player.mana_pool.dup
      error = attempt { seat.player.activate_ability(ability: source.ability) { |activation| activation.choose(chosen) if colors.size > 1 } }
      unless error
        added = seat.player.mana_pool.filter_map { |c, n| [c, n - before[c]] if n > before[c] }.to_h
        hand_taps << { player: seat.player, permanent: permanent, added: added }
      end
      error
    end
  end

  # Gives back the mana of a land tapped by hand (see #tap_for_mana_by_hand), untapping it, as long as that mana is
  # still in the pool. Returns nil on success, or the reason it failed.
  def untap_for_mana_by_hand(uid, permanent_id)
    @mutex.synchronize do
      seat = seat_for(uid)
      next "You are not in this game." unless seat && started?
      next CHOICE_PENDING if choice_pending?
      next "It is not your turn." unless acting_player == seat.player

      tap = refundable_taps(seat.player).find { |t| t[:permanent].object_id == permanent_id.to_i }
      next "That mana has already been used." unless tap

      tap[:permanent].untap!
      tap[:added].each { |color, n| seat.player.mana_pool[color] -= n }
      hand_taps.delete(tap)
      nil
    end
  end

  # Taps by hand whose mana is still floating and whose permanent is still tapped.
  def refundable_taps(player)
    hand_taps.select do |t|
      t[:player].equal?(player) && t[:permanent].tapped? && t[:added].all? { |color, n| player.mana_pool[color] >= n }
    end
  end

  def hand_taps
    @hand_taps ||= []
  end

  # Activates ability number +index+ (see #abilities_view) of one of +uid+'s permanents, paying its costs automatically.
  # Returns nil on success, or the reason it failed.
  def activate(uid, permanent_id, index)
    @mutex.synchronize do
      seat = seat_for(uid)
      next "You are not in this game." unless seat && started?
      next CHOICE_PENDING if choice_pending?
      next "It is not your turn." unless acting_player == seat.player

      permanent = seat.player.permanents.find { |perm| perm.object_id == permanent_id.to_i }
      next "No such permanent." unless permanent
      next "That ability can't be activated right now." unless activatable_ability?(seat.player, permanent, index.to_i)

      ability = non_mana_abilities(permanent)[index.to_i]
      if ability.respond_to?(:target_choices)
        lists = target_lists(ability)
        @pending_activation = ActivationPrompt.new(game: game, player: seat.player, permanent: permanent, index: index.to_i, choices: lists.first, lists: lists)
        next nil
      end

      cost = pick_cost(ability)
      if cost
        @pending_activation = CostPrompt.new(game: game, player: seat.player, permanent: permanent, index: index.to_i, cost: cost, choices: pick_choices(cost))
        next nil
      end

      attempt { perform_activation(game, seat.player, permanent, index.to_i) }
    end
  end

  # The player holding priority lets the top of the stack resolve (or lets the opponent respond to it in turn).
  # Returns nil on success, or the reason it is not allowed.
  def pass_priority(uid)
    @mutex.synchronize do
      seat = seat_for(uid)
      next "You are not in this game." unless seat && started?
      next "You do not have priority." unless @priority == seat.player

      attempt { @passed << seat.player }
    end
  end

  # The acting player moves the turn to its next step. After cleanup the next turn begins. In the declare attackers
  # and declare blockers steps this declares no attackers / no blockers.
  # Returns nil on success, or the reason it is not allowed.
  def advance_step(uid)
    @mutex.synchronize do
      seat = seat_for(uid)
      next "You are not in this game." unless seat && started?
      next CHOICE_PENDING if choice_pending?
      next "It is not your turn." unless acting_player == seat.player
      next RESPOND_FIRST if @priority

      attempt do
        case game.current_turn.step
        when "declare_attackers" then declare_attackers!(seat.player, [])
        when "declare_blockers" then declare_blockers!(seat.player, [])
        else step_forward!
        end
      end
    end
  end

  # +ids+ are Permanent ids (see #permanent_view) of the active player's creatures. Returns nil or the reason it failed.
  # +targets+ maps an attacker's id to the id of an opposing planeswalker it attacks; the rest attack the player.
  def declare_attackers(uid, ids, targets = {})
    @mutex.synchronize do
      seat = seat_for(uid)
      next "You are not in this game." unless seat && started?
      next CHOICE_PENDING if choice_pending?
      next "It is not your turn." unless acting_player == seat.player
      next "It is not the declare attackers step." unless game.current_turn.step == "declare_attackers"
      next RESPOND_FIRST if @priority

      attempt { declare_attackers!(seat.player, Array(ids), targets.to_h.transform_keys(&:to_s)) }
    end
  end

  # +pairs+ are [blocker id, attacker id]. Returns nil or the reason it failed.
  def declare_blockers(uid, pairs)
    @mutex.synchronize do
      seat = seat_for(uid)
      next "You are not in this game." unless seat && started?
      next CHOICE_PENDING if choice_pending?
      next "You are not the defending player." unless acting_player == seat.player
      next "It is not the declare blockers step." unless game.current_turn.step == "declare_blockers"
      next RESPOND_FIRST if @priority

      attempt { declare_blockers!(seat.player, Array(pairs)) }
    end
  end

  # Answers the pending choice; see ChoicePrompt for the shape of +answer+ per kind of choice.
  # Returns nil on success, or the reason it failed.
  def choose(uid, answer)
    @mutex.synchronize do
      seat = seat_for(uid)
      next "You are not in this game." unless seat && started?

      prompt = pending_prompt
      next "There is nothing to choose right now." unless prompt
      next "It is not your choice." unless prompt.controller == seat.player

      next choose_mulligan(prompt, answer) if prompt.equal?(@pending_mulligan)
      next choose_blocker_order(prompt, answer) if prompt.equal?(@pending_order)
      next choose_activation_target(prompt, answer) if prompt.equal?(@pending_activation)
      next choose_cast_modes(prompt, answer) if prompt.equal?(@pending_cast)

      attempt do
        prompt.resolve(answer)
        settle!
        auto_advance!
      end
    end
  end

  # Finishes (or cancels) an activation that was waiting for its target.
  def choose_activation_target(prompt, answer)
    if ActivationPrompt.cancel?(answer)
      @pending_activation = nil
      return nil
    end

    @pending_activation = nil
    if prompt.is_a?(CostPrompt)
      payment = prompt.payment_for(answer)
      return attempt { perform_activation(game, prompt.player, prompt.permanent, prompt.index, payment: payment) }
    end

    target = prompt.target_for(answer)
    targets = prompt.chosen + [target]
    if (next_choices = prompt.choices_after(target))
      @pending_activation = ActivationPrompt.new(game: game, player: prompt.player, permanent: prompt.permanent, index: prompt.index,
                                                 choices: next_choices, lists: prompt.lists, chosen: targets)
      return nil
    end

    attempt { perform_activation(game, prompt.player, prompt.permanent, prompt.index, targets: targets) }
  rescue StandardError => e
    note_error(e)
    @pending_activation = nil
    e.message
  end

  def choice_pending?
    !@pending_mulligan.nil? || !@pending_order.nil? || !@pending_activation.nil? || !@pending_cast.nil? || game.stack.pending_choices?
  end

  def seat_for(uid)
    seats.find { |s| s.uid == uid }
  end

  def started?
    !game.nil?
  end

  def over?
    started? && (!@conceded.nil? || game.over? || game.drawn?)
  end

  # The player named +uid+ gives up the game; the other player wins. Returns nil on success, or the reason it failed.
  def concede(uid)
    @mutex.synchronize do
      seat = seat_for(uid)
      next "You are not in this game." unless seat && started?
      next "The game is already over." if over?

      @conceded = seat.player
      @pending_mulligan = @pending_order = @pending_activation = @pending_cast = @priority = nil
      @log.add(:info, "#{seat.name} concedes")
      nil
    end
  end

  # Who won: the opponent of a player who conceded, otherwise whoever the engine says.
  def winner_name
    return nil unless started?
    return seats.find { |s| s.player != @conceded }&.name if @conceded

    game.winner&.name
  end

  # What +uid+ may see: own hand in full, the opponent's hand only as a count.
  def view_for(uid)
    # Within one view the game does not change, so copies of a card share the answer to "can it be paid for?".
    @view_checks = {}
    build_view_for(uid)
  ensure
    @view_checks = nil
  end

  private

  def build_view_for(uid)
    me = seat_for(uid)
    can_act = started? && !me.nil? && acting_player == me.player
    other = seats.find { |s| s != me }
    {
      id: id,
      deck: (me&.deck || @deck).name,
      decks: Deck::CHOICES.map { |name| { name: name, commander: Deck.load(name).commander } },
      status: started? ? "started" : "waiting",
      seated: !me.nil?,
      seat_count: seats.size,
      you: me && player_view(me, reveal: true),
      opponent: other && player_view(other, reveal: false),
      turn: started? ? { number: game.current_turn.number, active: game.current_turn.active_player.name, step: game.current_turn.step, steps: STEPS } : nil,
      can_act: can_act && !over?,
      over: over?,
      winner: winner_name,
      choice: choice_view(me),
      priority: !@priority.nil? && @priority == me&.player,
      stack: started? ? stack_view : [],
      exile: me && started? ? exile_view(me.player) : [],
      log: started? ? log.entries : [],
      can_play_land: can_act && game.current_turn.active_player == me.player && game.current_turn.main_phase? && game.stack.empty? && me.player.can_play_lands?
    }
  end

  def start_game!
    @game = Magic::Game.new
    seats.each do |seat|
      seat.player = Magic::Player.new(name: seat.name)
      game.add_player(seat.player)
      seat.deck.card_classes.each { |card_class| seat.player.library.add(card_class.new(game: game, owner: seat.player)) }
      # Command Tower and friends ask for the commander's colour identity: use the deck's first card.
      seat.player.add_commander(seat.deck.entries.first.card_class.new(game: game, owner: seat.player))
      seat.player.shuffle!
    end
    game.start!
    # Subscribed only now, so the fourteen opening-hand draws don't flood the log.
    game.subscribe(@log)
    game.stack.observer = @log
    @log.add(:info, "Each player drew an opening hand of #{seats.first.player.hand.count}")
    @log.turn(game.current_turn.number, game.current_turn.active_player.name)
    @mulligan_queue = seats.map(&:player)
    next_mulligan_decision!
  end

  # Asks the next player who has not yet kept their opening hand, or starts the game when everyone has.
  def next_mulligan_decision!
    player = @mulligan_queue.first
    if player
      @pending_mulligan = MulliganPrompt.new(game: game, player: player, taken: @mulligans.fetch(player, 0))
    else
      @pending_mulligan = nil
      auto_advance!
    end
  end

  # Answers a MulliganPrompt: keep, mulligan, or (once keeping after mulligans) which cards go to the bottom.
  def choose_mulligan(prompt, answer)
    player = prompt.player
    if prompt.stage == :bottom
      cards = prompt.cards_for(answer)
      cards.each do |card|
        player.hand.remove(card)
        player.library.add(card, player.library.count)
      end
      @log.add(:info, "#{player.name} kept #{player.hand.count} cards")
      return finish_mulligan(player)
    end

    if prompt.decision(answer) == "keep"
      return finish_mulligan(player) if prompt.taken.zero?

      @pending_mulligan = MulliganPrompt.new(game: game, player: player, taken: prompt.taken, stage: :bottom)
      return nil
    end

    # A copy of the list: the hand shrinks as its cards leave it.
    player.hand.cards.map(&:itself).each do |card|
      player.hand.remove(card)
      player.library.add(card)
    end
    player.shuffle!
    7.times { player.draw! }
    @mulligans[player] = prompt.taken + 1
    @log.add(:info, "#{player.name} takes a mulligan")
    @pending_mulligan = MulliganPrompt.new(game: game, player: player, taken: @mulligans[player])
    nil
  rescue StandardError => e
    note_error(e)
    e.message
  end

  def finish_mulligan(player)
    @mulligan_queue.delete(player)
    next_mulligan_decision!
    nil
  end

  # Runs the block, turning engine errors into a returned message. Returns nil on success.
  def attempt
    return "The game is over." if over?

    yield
    # Triggers (a land's enters-the-battlefield ability, say) go on the stack as part of an action; with no priority
    # passing in this game, resolve them straight away.
    settle!
    dismiss_empty_choices!
    nil
  rescue Magic::IllegalAction => e
    e.reason
  rescue StandardError => e
    note_error(e)
    Rails.logger.error("#{e.class}: #{e.message}\n#{e.backtrace.first(15).join("\n")}")
    warn "#{e.class}: #{e.message}\n#{e.backtrace.first(12).join("\n")}" if ENV["TABLE_DEBUG"]
    e.message
  end

  def step_forward!
    move_to_next_step
    auto_advance!
  end

  # Whoever has a decision to make: the defending player while blockers are declared, otherwise the active player.
  def acting_player
    return pending_prompt.controller if pending_prompt
    return @priority if @priority

    turn = game.current_turn
    # The defending player decides at declare blockers, and at the end step (the only reason to stop there is that they
    # can act: see #stop_here?).
    %w[declare_blockers end].include?(turn.step) ? defender : turn.active_player
  end

  def pending_choice
    game.stack.choices.first
  end

  def pending_prompt
    @pending_mulligan || @pending_order || @pending_activation || @pending_cast || (choice_prompt_for(pending_choice) if pending_choice)
  end

  def defender
    game.opponents(game.current_turn.active_player).first
  end

  # The prompt for an engine choice. The answers a choice with several questions has so far are kept here, since a new
  # prompt is built every time the choice is looked at.
  def choice_prompt_for(choice)
    @choice_partials ||= Hash.new { |hash, key| hash[key] = {} }
    ChoicePrompt.new(choice, game, partial: @choice_partials[choice.object_id], payer: ChoicePayer.new(self))
  end

  # The defending player, or one of their planeswalkers when +id+ names one.
  def attack_target(id)
    return defender if id.blank?

    defender.permanents.find { |perm| perm.object_id == id.to_i && perm.planeswalker? } || raise("That planeswalker can't be attacked.")
  end

  def find_permanent(player, id)
    player.permanents.find { |perm| perm.object_id == id.to_i } || raise("No such permanent.")
  end

  def declare_attackers!(player, ids, targets = {})
    actions = ids.map do |id|
      Magic::Actions::DeclareAttacker.new(game: game, player: player, attacker: find_permanent(player, id), target: attack_target(targets[id.to_s]))
    end
    actions.each { |action| raise Magic::IllegalAction.new(action, action.illegal_reason) if action.illegal_reason }
    actions.each { |action| game.take_action(action) }
    step_forward!
  end

  def declare_blockers!(player, pairs)
    attackers = game.current_turn.attacks.map(&:attacker)
    actions = pairs.map do |blocker_id, attacker_id|
      attacker = attackers.find { |a| a.object_id == attacker_id.to_i } || raise("No such attacker.")
      Magic::Actions::DeclareBlocker.new(game: game, player: player, blocker: find_permanent(player, blocker_id), attacker: attacker)
    end
    actions.each { |action| raise Magic::IllegalAction.new(action, action.illegal_reason) if action.illegal_reason }
    # Some rules (menace) only fail once all blocks are known, and the engine checks them when combat moves on, by
    # which point the blocks cannot be taken back. Rehearse on a copy of the game first.
    raise rehearse_blocks(player, actions) if rehearse_blocks(player, actions)

    actions.each { |action| game.take_action(action) }
    return if ask_blocker_order!

    step_forward!
  end

  # An attacker blocked by several creatures has its controller order them; asks about the first such attacker, and
  # returns true when there is a question to answer.
  def ask_blocker_order!(done: [])
    attack = game.current_turn.attacks.find { |a| !done.include?(a) && a.blockers.size > 1 }
    return false unless attack

    @blocker_orders_done = done
    @pending_order = BlockerOrderPrompt.new(game: game, player: attack.attacker.controller, attack: attack)
    true
  end

  # Answers a BlockerOrderPrompt; reorders the attack's blockers once each has been placed, then moves on to the next
  # attacker with several blockers, or to combat damage.
  def choose_blocker_order(prompt, answer)
    return choose_damage_division(prompt, answer) if prompt.is_a?(DamagePrompt)

    ordered = prompt.ordered + [prompt.blocker_for(answer)]
    remaining = prompt.attack.blockers - ordered
    if remaining.size > 1
      @pending_order = BlockerOrderPrompt.new(game: game, player: prompt.player, attack: prompt.attack, ordered: ordered)
      return nil
    end

    prompt.attack.blockers.replace(ordered + remaining)
    @pending_order = DamagePrompt.new(game: game, player: prompt.player, attack: prompt.attack)
    nil
  rescue StandardError => e
    e.message
  end

  # Answers a DamagePrompt: the engine checks the division; then on to the next attacker with several blockers, or to
  # combat damage. A division that is not allowed leaves the question open.
  def choose_damage_division(prompt, answer)
    game.current_turn.assign_combat_damage(prompt.attack.attacker, prompt.assignment_for(answer))
    done = @blocker_orders_done + [prompt.attack]
    @pending_order = nil
    return nil if ask_blocker_order!(done: done)

    attempt { step_forward! }
  rescue StandardError => e
    e.message
  end

  # Returns nil when +actions+ (DeclareBlocker) make a legal set of blocks, otherwise the reason they do not.
  def rehearse_blocks(player, actions)
    copy = Marshal.load(Marshal.dump(game))
    copy_player = copy.players.find { |p| p.name == player.name }
    mine = player.permanents.to_a
    attacks = game.current_turn.attacks
    actions.each do |action|
      blocker = copy_player.permanents.to_a[mine.index(action.blocker)]
      attacker = copy.current_turn.attacks[attacks.index { |attack| attack.attacker == action.attacker }].attacker
      copy.take_action(Magic::Actions::DeclareBlocker.new(game: copy, player: copy_player, blocker: blocker, attacker: attacker))
    end
    copy.current_turn.combat.validate_blocks!
    nil
  rescue Magic::IllegalAction => e
    e.reason
  rescue StandardError => e
    e.message
  end

  def non_mana_abilities(permanent)
    abilities = permanent.activated_abilities.reject { |ability| ability.is_a?(Magic::ManaAbility) }
    abilities += permanent.loyalty_abilities if permanent.planeswalker?
    abilities
  end

  # Abilities with costs beyond tapping/sacrificing the permanent itself and mana are not offered yet.
  def activatable_ability?(player, permanent, index)
    ability = non_mana_abilities(permanent)[index]
    return false if ability.nil?
    return false if ability.respond_to?(:target_choices) && target_lists(ability).any?(&:empty?)
    return loyalty_activatable?(player, ability) if ability.is_a?(Magic::LoyaltyAbility)

    action = Magic::Actions::ActivateAbility.new(game: game, player: player, ability: ability)
    return false if action.illegal_reason || !ability.requirements_met?
    return false unless action.costs.all? { |cost| (SELF_COSTS + PICK_COSTS).any? { |kind| cost.is_a?(kind) } }
    return false if pick_cost(ability) && (ability.respond_to?(:target_choices) || !pick_cost_payable?(pick_cost(ability)))
    return false if action.costs.any? { |cost| cost.respond_to?(:unpayable_reason) && cost.unpayable_reason }
    return false if action.costs.any? { |cost| cost.is_a?(Magic::Costs::RemoveCounter) && !cost.can_pay? }
    return false if action.costs.any? { |cost| cost.is_a?(Magic::Costs::PayLife) && !cost.can_pay?(player) }

    mana = action.costs.find { |cost| cost.is_a?(Magic::Costs::Mana) }
    return true if mana.nil? || mana.zero?

    rehearse_activation(player, permanent, index)
  end

  def pick_cost(ability)
    return unless ability.respond_to?(:costs)

    ability.costs.find { |cost| PICK_COSTS.any? { |kind| cost.is_a?(kind) } }
  end

  def pick_cost_payable?(cost)
    cost.is_a?(Magic::Costs::Discard) ? cost.can_pay? && cost.valid_targets.any? : pick_choices(cost).size >= pick_count(cost)
  end

  # What can be paid for a pick cost.
  def pick_choices(cost)
    case cost
    when Magic::Costs::Discard then cost.valid_targets
    when Magic::Costs::MultiTap then cost.candidates.to_a
    else cost.choices.to_a
    end
  end

  # How many permanents or cards a pick cost takes.
  def pick_count(cost)
    return cost.count if cost.is_a?(Magic::Costs::MultiTap)

    cost.respond_to?(:amount) ? cost.amount : 1
  end

  # Whether a pick cost is paid with a list (several permanents) rather than one thing.
  def pick_list?(cost)
    cost.is_a?(Magic::Costs::MultiTap) || cost.respond_to?(:amount)
  end

  # What a rehearsal (on a copy of the game) pays for a pick cost: the first legal choice(s).
  def default_payment(cost)
    options = pick_choices(cost)
    pick_list?(cost) ? options.first(pick_count(cost)) : options.first
  end

  # Pays a pick cost on +activation+ with +paid+ (what #default_payment or the player's answer gave).
  def pay_pick_cost(activation, cost, paid)
    case cost
    when Magic::Costs::Discard then activation.pay_discard(paid)
    when Magic::Costs::MultiTap then activation.pay_multi_tap(paid)
    else activation.pay_sacrifice(paid)
    end
  end

  # The legal targets of an ability, one list per target it has (see ActivationPrompt).
  def target_lists(ability)
    lists = ability.multi_target? ? ability.target_choices.map(&:to_a) : [ability.target_choices.to_a]
    lists.map { |choices| choices.select { |target| ability.legal_target?(target, choices) } }
  end

  def loyalty_activatable?(player, ability)
    Magic::Actions::ActivateLoyaltyAbility.new(game: game, player: player, ability: ability).illegal_reason.nil?
  end

  # Does the whole activation (tapping sources for its mana cost, then paying) work on a copy of the game?
  def rehearse_activation(player, permanent, index)
    copy = Marshal.load(Marshal.dump(game))
    copy_player = copy.players.find { |p| p.name == player.name }
    copy_permanent = copy_player.permanents.to_a[player.permanents.to_a.index(permanent)]
    perform_activation(copy, copy_player, copy_permanent, index)
    true
  rescue Magic::Costs::Mana::CannotPay, Magic::Player::UnpayableMana, Magic::IllegalAction, NotEnoughMana
    false
  rescue StandardError => e
    report_unexpected(e, "checking whether #{permanent.name} can be activated")
    false
  end

  class NotEnoughMana < StandardError; end

  def perform_activation(game, player, permanent, index, targets: [], payment: nil)
    ability = non_mana_abilities(permanent)[index]
    return player.activate_loyalty_ability(ability: ability) { |activation| activation.targeting(*targets) if targets.any? } if ability.is_a?(Magic::LoyaltyAbility)

    run_ability(game, player, ability, targets: targets, payment: payment)
  end

  # Taps lands for an ability's mana cost, pays its other costs and puts it on the stack.
  def run_ability(game, player, ability, targets: [], payment: nil)
    mana = Magic::Actions::ActivateAbility.new(game: game, player: player, ability: ability).costs.find { |cost| cost.is_a?(Magic::Costs::Mana) }
    if mana && !mana.zero?
      paid_for = Struct.new(:mana_cost).new(mana)
      raise NotEnoughMana, "Not enough mana." unless tap_for_mana(game, player, paid_for, restricted: false)
    end
    player.activate_ability(ability: ability) do |activation|
      activation.targeting(*targets) if targets.any?
      pick = pick_cost(activation)
      if pick
        paid = payment || default_payment(pick)
        pay_pick_cost(activation, pick, paid)
      end
      cost = activation.costs.find { |c| c.is_a?(Magic::Costs::Mana) }
      cost.auto_pay(player: player) if cost && !cost.zero?
    end
  end

  def ability_label(ability)
    return loyalty_label(ability) if ability.is_a?(Magic::LoyaltyAbility)

    parts = ability.costs.map do |cost|
      case cost
      when Magic::Costs::SelfTap then "{T}"
      when Magic::Costs::SelfSacrifice then "Sacrifice"
      when Magic::Costs::SelfExile then "Exile"
      when Magic::Costs::SacrificeNonlandPermanents then "Sacrifice #{cost.amount} nonland permanents"
      when Magic::Costs::SacrificeAnother then "Sacrifice another creature"
      when Magic::Costs::Sacrifice then "Sacrifice a creature"
      when Magic::Costs::Discard then "Discard a card"
      when Magic::Costs::Mana then cost.cost.map { |color, n| color == :generic ? "{#{n}}" : "{#{color.to_s[0].upcase}}" * n }.join
      else cost.class.name.demodulize.titleize
      end
    end
    # Most cards just call theirs ActivatedAbility, which says nothing; others (Draw Ability) are worth showing.
    name = ability.class.name.demodulize
    "#{parts.join(', ')}: #{name == 'ActivatedAbility' ? 'Use ability' : name.titleize}"
  end

  def loyalty_label(ability)
    change = ability.loyalty_change
    sign = change.is_a?(Integer) && change.positive? ? "+#{change}" : change.to_s.tr("-", "−")
    "[#{sign}]: #{ability.class.name.demodulize.titleize}"
  end

  # Activates ability number +index+ of a card in +uid+'s graveyard (Crown of Skemfar's "{2}{G}: Return this card to your
  # hand"), paying its costs automatically. Returns nil on success, or the reason it failed.
  def activate_from_graveyard(uid, card_id, index)
    @mutex.synchronize do
      seat = seat_for(uid)
      next "You are not in this game." unless seat && started?
      next CHOICE_PENDING if choice_pending?
      next "It is not your turn." unless acting_player == seat.player

      card = seat.player.graveyard.cards.find { |c| c.object_id == card_id.to_i }
      next "No such card in your graveyard." unless card

      ability = card.graveyard_abilities[index.to_i]
      next "That ability can't be activated right now." unless ability && graveyard_ability_activatable?(seat.player, ability)

      attempt { run_ability(game, seat.player, ability) }
    end
  end

  public :activate_from_graveyard

  # The cards in +player+'s graveyard that have abilities usable from there, for the viewer to offer.
  def graveyard_abilities_view(player)
    can_act = !over? && !choice_pending? && acting_player == player
    player.graveyard.cards.filter_map do |card|
      abilities = card.graveyard_abilities
      next if abilities.empty?

      { id: card.object_id, name: card.name,
        abilities: abilities.each_with_index.map { |ability, index| { index: index, label: ability_label(ability), activatable: can_act && graveyard_ability_activatable?(player, ability) } } }
    end
  end

  # An ability with no target, whose costs are mana (and "Exile this"), that the player can pay for now.
  def graveyard_ability_activatable?(player, ability)
    return false if ability.respond_to?(:target_choices)

    action = Magic::Actions::ActivateAbility.new(game: game, player: player, ability: ability)
    return false if action.illegal_reason || !ability.requirements_met?
    return false unless action.costs.all? { |cost| [Magic::Costs::Mana, Magic::Costs::SelfExile].any? { |kind| cost.is_a?(kind) } }

    mana = action.costs.find { |cost| cost.is_a?(Magic::Costs::Mana) }
    mana.nil? || mana.zero? || payable?(player, mana.cost.to_h)
  end

  # Non-mana abilities of +permanent+ for its owner, each marked with whether it can be activated right now.
  def abilities_view(player, permanent)
    return [] if over? || choice_pending? || acting_player != player

    non_mana_abilities(permanent).each_with_index.map do |ability, index|
      { index: index, label: ability_label(ability), activatable: activatable_ability?(player, permanent, index) }
    end
  end

  def can_attack?(player, permanent)
    return false unless permanent.creature?

    Magic::Actions::DeclareAttacker.new(game: game, player: player, attacker: permanent, target: defender).illegal_reason.nil?
  end

  def can_block?(player, permanent)
    return false unless permanent.creature?

    game.current_turn.attacks.any? do |attack|
      Magic::Actions::DeclareBlocker.new(game: game, player: player, blocker: permanent, attacker: attack.attacker).illegal_reason.nil?
    end
  end

  # A combat step is only worth stopping at when the player has a creature that can take part in it.
  def stop_here?
    return true if choice_pending?

    turn = game.current_turn
    case turn.step
    when *STOP_STEPS then true
    when "declare_attackers" then turn.active_player.permanents.any? { |perm| can_attack?(turn.active_player, perm) }
    when "declare_blockers"
      defender.permanents.any? { |perm| can_block?(defender, perm) } || (turn.attacks.any? && can_respond?(defender))
    when "end" then can_respond?(defender) # the opponent's chance to act before the turn is over
    else false
    end
  end

  # Could the spell be given everything it needs: enough modes that have something to target, and a legal target for each
  # target it has?
  def targets_available?(player, card, action)
    return false if card.modes.any? && !action.modes_satisfiable?

    # "target creature with mana value X" (Stolen by the Fae): castable if some X leaves a legal target.
    if card.respond_to?(:target_fits_x?) && card.cost.cost.key?(:x)
      return (0..max_x_for_spell(player, card, Struct.new(:kicker).new(false))).any? do |x|
        with_x = Magic::Actions::Cast.new(game: game, player: player, card: card, value_for_x: x)
        target_slots(player, card, with_x, nil, x: x).none? { |slot| slot.choices.empty? }
      end
    end

    target_slots(player, card, action, card.modes.any? ? action.available_modes : nil).none? { |slot| slot.choices.empty? }
  end

  # A card in +zone+: the hand, or the top of the library (Courser of Kruphix: "play lands from the top").
  # Or a card in exile that something lets the player cast (Cunning Rhetoric).
  def card_in(player, zone, index)
    case zone.to_s
    when "library" then player.library.first
    when "exile" then game.exile.to_a[index.to_i]
    else player.hand.cards[index.to_i]
    end
  end

  # The same card in a copy of the game (see #affordable?).
  def copy_of_card(copy, player, copy_player, card)
    return copy_player.library.first if player.library.first.equal?(card)
    return copy.exile.to_a[game.exile.to_a.index(card)] if game.exile.to_a.include?(card)

    copy_player.hand.cards[player.hand.cards.index(card)]
  end

  # Does a battlefield effect make the top card of +player+'s library public ("play with the top card revealed")?
  def top_card_revealed?(player)
    game.battlefield.static_abilities.any? { |ability| ability.respond_to?(:reveals_top_card?) && ability.reveals_top_card?(player) }
  end

  # The revealed top card of a library, or nil. For its owner it also says whether it can be played right now.
  # Every exiled card, face up, with whether +player+ may cast it from there.
  def exile_view(player)
    game.exile.to_a.each_with_index.map do |card, index|
      { name: card.name, owner: card.owner.name, index: index, castable: castable?(player, card) }
    end
  end

  def library_top_view(player, reveal:)
    card = player.library.first
    return unless card && top_card_revealed?(player)

    view = { name: card.name, land: card.land? }
    return view unless reveal

    view.merge(
      playable_land: card.land? && acting_player == player && !choice_pending? &&
        Magic::Actions::PlayLand.new(game: game, player: player, card: card).illegal_reason.nil?,
      castable: castable?(player, card)
    )
  end

  # Mana abilities +player+ could activate right now: untapped, and not summoning sick for creatures.
  def mana_sources(game, player)
    player.permanents.flat_map(&:activated_abilities).grep(Magic::ManaAbility).filter_map do |ability|
      source = Magic::Actions::ActivateManaAbility.new(game: game, player: player, ability: ability)
      next unless source.legal?
      next if source.has_cost?(Magic::Costs::SelfTap) && source.costs.find { |c| c.is_a?(Magic::Costs::SelfTap) }.unpayable_reason

      source
    end
  end

  # The mana ability of +permanent+ that can be tapped by hand now: no mana cost of its own, and able to make a colour.
  def free_mana_source(player, permanent)
    return nil unless permanent

    mana_sources(game, player).find do |s|
      s.ability.source.equal?(permanent) && !mana_cost_of(s) && ability_colors(s.ability).any?
    end
  end

  # Colours +permanent+ can be tapped for by hand right now, as [] when it can't be.
  def mana_colors_view(player, permanent)
    return [] unless started? && !over? && !choice_pending? && acting_player == player

    source = free_mana_source(player, permanent)
    source ? ability_colors(source.ability).map(&:to_s) : []
  end

  def ability_colors(ability)
    ability.choices
  rescue StandardError
    []
  end

  def mana_cost_of(source)
    source.costs.find { |cost| cost.is_a?(Magic::Costs::Mana) }
  end

  # Taps mana sources in +game+ until +action+'s mana cost can be paid from +player+'s pool, preferring sources that
  # can make a colour the cost asks for. Sources with a mana cost of their own ("{1}, {T}: Add {G}{W}", Sungrass
  # Prairie) are used only once the free ones run out, paying that cost from what is already in the pool. Returns true
  # if the cost can then be paid. Works on any copy of the game, so #affordable? can rehearse it without side effects.
  #
  # +restricted+: false when what is being paid is not a spell (a choice's "you may pay {1}", an ability, cycling):
  # mana that can only be spent on certain spells (Path of Ancestry's) cannot pay for it, so those sources are left alone.
  def tap_for_mana(game, player, action, restricted: true)
    cost = action.mana_cost
    needed = cost.cost.keys - [:generic, :x]
    broken = []
    until cost.zero? || (restricted ? cost.can_pay?(player) : pool_covers?(player, cost))
      # A source that cannot make mana right now (Exotic Orchard when no opposing land makes any) or that blows up is
      # left out rather than sinking the whole payment.
      sources = mana_sources(game, player).reject do |s|
        broken.include?(s.ability) || ability_colors(s.ability) == [] || (!restricted && s.ability.mana_restriction)
      end
      free = sources.reject { |s| mana_cost_of(s) }
      if (source = free.min_by { |s| (ability_colors(s.ability) & needed).any? ? 0 : 1 })
        colors = ability_colors(source.ability)
        color = colors.find { |c| needed.include?(c) && player.mana_pool[c] < cost.cost[c].to_i } || colors.first
        begin
          player.activate_ability(ability: source.ability) { |activation| activation.choose(color) if colors.size > 1 }
        rescue StandardError => e
          report_unexpected(e, "tapping #{source.ability.source.name} for mana")
          broken << source.ability
        end
      else
        source = sources.find { |s| payable_from_pool?(player, mana_cost_of(s)) && s.can_be_activated?(player) } or return false
        pay_with_pool(player, source, cost)
      end
    end
    true
  end

  # Does the player's ordinary mana pool (not mana restricted to some spells) cover +cost+?
  def pool_covers?(player, cost)
    wanted = cost.cost.to_h.except(:generic, :x)
    pool = player.mana_pool.to_h
    wanted.all? { |color, amount| pool[color].to_i >= amount } &&
      pool.values.sum - wanted.values.sum >= cost.cost[:generic].to_i
  end

  # A source's own cost can be generic ("{1}, {T}") or hybrid ("{U/R}, {T}", the filter lands), paid from the pool.
  def payable_from_pool?(player, mana_cost)
    !pool_payment(player, mana_cost, nil).nil?
  end

  # What to spend from the pool on a source's own cost, as a `pay_mana` hash ({ generic: { red: 1 }, blue: 1 }), or nil
  # when the pool can't cover it. Generic mana is paid with the colours the spell needs least; a hybrid symbol is paid
  # with whichever of its colours the pool has the most of.
  def pool_payment(player, mana_cost, spell_cost)
    left = player.mana_pool.to_h.dup
    left.default = 0
    payment = {}
    generic = Hash.new(0)
    wanted = mana_cost.cost.to_h

    wanted.each do |key, amount|
      next if key == :generic

      colors = key.to_s.split("_or_").map(&:to_sym)
      return nil unless key.to_s.include?("_or_")

      amount.times do
        color = colors.select { |c| left[c] > 0 }.max_by { |c| left[c] } or return nil
        left[color] -= 1
        payment[color] = payment.fetch(color, 0) + 1
      end
    end

    wanted.fetch(:generic, 0).times do
      color = left.keys.select { |c| left[c] > 0 }.max_by { |c| left[c] - (spell_cost ? spell_cost.cost[c].to_i : 0) } or return nil
      left[color] -= 1
      generic[color] += 1
    end

    generic.any? ? payment.merge(generic: generic) : payment
  end

  # Activates a mana source that has a cost of its own, paying it from the pool.
  def pay_with_pool(player, source, spell_cost)
    payment = pool_payment(player, mana_cost_of(source), spell_cost)
    colors = ability_colors(source.ability)
    choice = colors.max_by { |name| filter_choice_score(player, name, spell_cost) }
    player.activate_ability(ability: source.ability) do |activation|
      activation.choose(choice) if colors.size > 1
      activation.pay_mana(**payment)
    end
  end

  # How useful a mana choice is for a spell: a filter land's "blue_red" counts each colour the spell still needs and
  # the pool lacks. A plain colour choice (:green) counts the same way.
  def filter_choice_score(player, name, spell_cost)
    needed = spell_cost.cost.to_h.except(:generic, :x)
    name.to_s.split("_").count { |part| (color = part.to_sym) && needed[color].to_i > player.mana_pool[color].to_i }
  end

  # Could +player+ pay for +card+ by tapping sources? Rehearses the whole payment on a copy of the game.
  def affordable?(player, card)
    return affordable_uncached?(player, card) unless @view_checks

    @view_checks.fetch([:affordable, player, card.class, x_value(card)]) { @view_checks[[:affordable, player, card.class, x_value(card)]] = affordable_uncached?(player, card) }
  end

  def affordable_uncached?(player, card)
    copy = Marshal.load(Marshal.dump(game))
    copy_player = copy.players.find { |p| p.name == player.name }
    copy_card = copy_of_card(copy, player, copy_player, card)
    tap_for_mana(copy, copy_player, Magic::Actions::Cast.new(game: copy, player: copy_player, card: copy_card, value_for_x: x_value(card)))
  rescue Magic::Costs::Mana::CannotPay, Magic::Player::UnpayableMana, Magic::IllegalAction
    false
  rescue StandardError => e
    report_unexpected(e, "checking whether #{card.name} is affordable")
    false
  end

  # An engine error we did not expect. Raised in development and test so the bug is seen at once; in production the
  # player just loses that option and the error is logged with its backtrace.
  def report_unexpected(error, doing)
    Rails.logger.error("Unexpected #{error.class} while #{doing}: #{error.message}\n#{error.backtrace.first(15).join("\n")}")
    raise error if Rails.env.local?
  end

  # Mana does not carry over between steps.
  def empty_mana_pools!
    game.players.each { |p| p.mana_pool.each_key { |color| p.mana_pool[color] = 0 } }
    hand_taps.clear
  end

  def move_to_next_step
    empty_mana_pools!
    turn = game.current_turn
    if turn.step == "cleanup"
      game.next_turn
      @log.turn(game.current_turn.number, game.current_turn.active_player.name)
    elsif turn.number == 1 && turn.step == "upkeep"
      without_drawing(turn.active_player) { turn.advance_step! }
    else
      turn.advance_step!
    end
  end

  # The player who goes first skips their first draw step. mtg has no switch for that yet.
  def without_drawing(player)
    player.define_singleton_method(:can_draw?) { false }
    yield
  ensure
    player.singleton_class.remove_method(:can_draw?)
  end

  # Passes through steps with nothing to decide, stopping at the next main phase.
  def auto_advance!
    dismiss_empty_choices!
    MAX_AUTO_STEPS.times do
      break if stop_here?

      move_to_next_step
      dismiss_empty_choices!
    end
  end

  # Resolves the stack from the top, one item at a time. Before each item resolves, the player who did not put it there
  # gets a chance to respond, but only when they could (see #can_respond?); then #priority is theirs and this returns,
  # to be called again once they have cast something, activated something or passed.
  def settle!
    @priority = nil
    loop do
      game.check_state_based_actions!
      break if game.stack.pending_choices? || game.stack.empty?

      signature = [game.stack.count, game.stack.first.object_id]
      (@passed.clear; @stack_signature = signature) unless signature == @stack_signature
      responder = game.players.find { |p| p != stack_item_controller(game.stack.first) }
      if responder && !@passed.include?(responder) && !game.stack.first.nil? && can_respond?(responder)
        @priority = responder
        break
      end

      game.stack.resolve!
      @passed.clear
      @stack_signature = nil
    end
  end

  def stack_item_controller(item)
    item.respond_to?(:player) ? item.player : item.controller
  end

  # Could +player+ cast a spell or activate an ability right now, with something on the stack or in a combat step?
  def can_respond?(player)
    return false if over? || player.nil?

    player.hand.cards.any? { |card| !card.land? && castable?(player, card) } ||
      player.permanents.any? { |permanent| non_mana_abilities(permanent).each_index.any? { |index| activatable_ability?(player, permanent, index) } }
  end

  def stack_item_name(item)
    return item.card.name if item.is_a?(Magic::Actions::Cast)
    return "#{item.ability.source.name} ability" if item.respond_to?(:ability) && item.ability.respond_to?(:source)
    return "#{item.actor.name} trigger" if item.is_a?(Magic::TriggeredAbility) && item.actor.respond_to?(:name)

    item.respond_to?(:source) ? "#{item.source.name} ability" : item.to_s
  end

  def stack_view
    game.stack.map { |item| { name: stack_item_name(item), controller: stack_item_controller(item).name } }
  end

  def dismiss_empty_choices!
    while !@pending_activation && (prompt = pending_prompt)
      if prompt.respond_to?(:auto_resolve?) && prompt.auto_resolve?
        # Every question has been answered or had nothing to pick: the choice goes ahead with the answers it has.
        prompt.resolve(nil)
        settle!
      elsif prompt.nothing_to_choose?
        source = prompt.source_name
        log.skipped(pending_choice, "#{prompt.controller.name} had nothing to choose#{" for #{source}" if source}, so it was skipped")
        game.skip_choice!
        settle!
      else
        break
      end
    end
  end

  # What a ChoicePrompt needs from the table to pay mana for a choice ("you may pay {X}{X}").
  class ChoicePayer
    def initialize(table)
      @table = table
    end

    def payable?(choice, cost)
      @table.send(:payable?, choice.controller, cost)
    end

    # The largest X (up to ten) the player's lands can pay for.
    def max_x(choice)
      (0..10).take_while { |x| x.zero? || @table.send(:payable?, choice.controller, choice.payment_cost(x)) }.last
    end

    # Taps lands for +cost+ ({ generic: 2, green: 1 }) and returns the { color => amount } to pay it from the pool.
    def pay(choice, cost)
      @table.send(:pay_for_choice, choice.controller, cost)
    end
  end

  # Could +player+ pay +cost+ by tapping their lands? Tried on a copy of the game.
  def payable?(player, cost)
    copy = Marshal.load(Marshal.dump(game))
    copy_player = copy.players.find { |p| p.name == player.name }
    tap_for_mana(copy, copy_player, Struct.new(:mana_cost).new(Magic::Costs::Mana.new(cost)), restricted: false)
  rescue Magic::Costs::Mana::CannotPay, Magic::Player::UnpayableMana, Magic::IllegalAction
    false
  end

  def pay_for_choice(player, cost)
    raise "Not enough mana." unless tap_for_mana(game, player, Struct.new(:mana_cost).new(Magic::Costs::Mana.new(cost)), restricted: false)

    payment_from_pool(player, cost)
  end

  # The { color => amount } that pays +cost+ ({ generic: 2, green: 1 }) from what is in the player's pool: the coloured
  # parts exactly, the generic part from whatever else is there, keeping +reserve+ (a { color => amount } hash) back.
  def payment_from_pool(player, cost, reserve: {})
    payment = cost.reject { |color, _| color == :generic }.dup
    pool = player.mana_pool.to_h.to_h { |color, count| [color, count - payment.fetch(color, 0) - reserve.fetch(color, 0)] }
    generic = cost.fetch(:generic, 0)
    pool.sort_by { |_, count| -count }.each do |color, count|
      break if generic.zero?

      take = [count, generic].min
      next if take <= 0

      payment[color] = payment.fetch(color, 0) + take
      generic -= take
    end
    raise "Not enough mana." unless generic.zero?

    payment
  end

  # The pending choice as +me+ sees it: full options for the chooser, just a notice for everyone else.
  def choice_view(me)
    prompt = started? ? pending_prompt : nil
    return unless prompt

    chooser = prompt.controller == me&.player
    view = { chooser: chooser, chooser_name: prompt.controller.name }
    chooser ? view.merge(prompt.view) : view
  rescue ChoicePrompt::Unsupported => e
    { chooser: chooser, chooser_name: prompt.controller.name, kind: "unsupported", prompt: e.message }
  end

  def hand_card_view(player, card)
    { name: card.name, land: card.land?, castable: castable?(player, card), cyclable: cyclable?(player, card),
      back_face: (card.back_face&.name if card.land?) }
  end

  def cyclable?(player, card)
    return false unless card.cycling? && started? && !over? && game.current_turn.active_player == player && !choice_pending?
    return cyclable_uncached?(player, card) unless @view_checks

    @view_checks.fetch([:cyclable, player, card.class]) { @view_checks[[:cyclable, player, card.class]] = cyclable_uncached?(player, card) }
  end

  def cyclable_uncached?(player, card)
    copy = Marshal.load(Marshal.dump(game))
    copy_player = copy.players.find { |p| p.name == player.name }
    copy_card = copy_player.hand.cards[player.hand.cards.index(card)]
    tap_for_mana(copy, copy_player, Magic::Actions::Cycle.new(game: copy, player: copy_player, card: copy_card), restricted: false)
  rescue Magic::Costs::Mana::CannotPay, Magic::Player::UnpayableMana, Magic::IllegalAction
    false
  rescue StandardError => e
    report_unexpected(e, "checking whether #{card.name} can be cycled")
    false
  end

  def castable?(player, card)
    return false if card.land? || !started?
    return false if over? || (@priority && @priority != player)
    # Nothing can be cast while a choice is pending.
    return false if choice_pending?

    action = Magic::Actions::Cast.new(game: game, player: player, card: card, value_for_x: x_value(card))
    return false unless action.illegal_reason.nil? && sacrifice_costs_payable?(action) &&
                        (affordable?(player, card) || life_payable?(player, card))

    targets_available?(player, card, action)
  end

  def player_view(seat, reveal:)
    player = seat.player
    {
      name: seat.name,
      life: player&.life,
      library: player&.library&.count,
      library_top: player && started? ? library_top_view(player, reveal: reveal) : nil,
      hand_size: player&.hand&.count,
      mana_pool: player ? player.mana_pool.select { |_, n| n.positive? }.transform_keys(&:to_s) : {},
      graveyard: player ? player.graveyard.cards.map(&:name) : [],
      graveyard_abilities: reveal && player ? graveyard_abilities_view(player) : [],
      hand: reveal && player ? player.hand.map { |card| hand_card_view(player, card) } : nil,
      battlefield: player ? player.permanents.map { |permanent| permanent_view(player, permanent, reveal: reveal) } : []
    }
  end

  # Counters on a permanent as [{ name: "quest", count: 2 }], with the +1/+1 style names players know.
  def counters_view(permanent)
    permanent.counters.group_by(&:class).map do |counter_class, counters|
      name = case counter_class.name.demodulize
      when "Plus1Plus1" then "+1/+1"
      when "Minus1Minus1" then "-1/-1"
      else counter_class.name.demodulize.underscore.tr("_", " ")
      end
      { name: name, count: counters.size }
    end
  end

  def permanent_view(player, permanent, reveal: false)
    attack = started? ? game.current_turn.attacks.find { |a| a.attacker == permanent } : nil
    blocking = started? ? game.current_turn.attacks.find { |a| a.blockers.include?(permanent) } : nil
    {
      id: permanent.object_id,
      name: permanent.name,
      tapped: permanent.tapped?,
      land: permanent.card.land?,
      token: permanent.token?,
      counters: counters_view(permanent),
      attached_to: permanent.respond_to?(:attached_to) ? permanent.attached_to&.object_id : nil,
      planeswalker: permanent.planeswalker?,
      abilities: reveal ? abilities_view(player, permanent) : [],
      mana_colors: reveal ? mana_colors_view(player, permanent) : [],
      mana_refundable: reveal && started? && !choice_pending? && acting_player == player && refundable_taps(player).any? { |t| t[:permanent].equal?(permanent) },
      power: permanent.creature? ? permanent.power : nil,
      toughness: permanent.creature? ? permanent.toughness : nil,
      damage: permanent.creature? ? permanent.damage : 0,
      attacking: !attack.nil?,
      blocking: blocking&.attacker&.object_id,
      can_attack: started? && game.current_turn.step == "declare_attackers" && game.current_turn.active_player == player && can_attack?(player, permanent),
      can_block: started? && game.current_turn.step == "declare_blockers" && defender == player && can_block?(player, permanent)
    }
  end
end
