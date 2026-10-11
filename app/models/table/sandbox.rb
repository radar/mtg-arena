class Table
  # Sets a table up in a given game state, for trying one card interaction without playing to it (see SandboxController and
  # script/sandbox). Development and test only.
  #
  #   table.sandbox!(uid, you: { hand: ["Escape to the Wilds"], battlefield: ["Forest", { name: "Azusa's Many Journeys", counters: { lore: 2 } }] },
  #                       opponent: { battlefield: ["Grizzly Bears"] })
  #
  # +uid+ takes the seat of the player whose turn it is, in their first main phase with an empty stack. Each side may give
  # +hand+ (always replaces the opening hand), +battlefield+ (permanents that are not summoning sick; a Hash with +name+,
  # +tapped+ and +counters+ for more), +library+ (put on top, first card on top) and +graveyard+.
  module Sandbox
    def sandbox!(uid, given = {})
      raise "The sandbox is for development and test only." unless Rails.env.development? || Rails.env.test?

      given = given.to_h.with_indifferent_access
      @mutex.synchronize do
        join(uid)
        join("sandbox-opponent")
        @mulligan_queue.clear
        @pending_mulligan = nil
        auto_advance!

        yours, theirs = seats.partition { |seat| seat.player == game.current_turn.active_player }.flatten
        yours.uid, theirs.uid = uid, "sandbox-opponent"
        sandbox_side(yours.player, given[:you])
        sandbox_side(theirs.player, given[:opponent])
        settle!
        dismiss_empty_choices!
        log.clear!
        nil
      end
    end

    private

    def sandbox_side(player, spec)
      spec = (spec || {}).to_h.with_indifferent_access
      player.hand.cards.dup.each { |card| player.hand.remove(card) }
      Array(spec[:hand]).each { |name| player.hand.add(sandbox_card(player, name)) }
      Array(spec[:library]).reverse_each { |name| player.library.add(sandbox_card(player, name)) }
      Array(spec[:graveyard]).each { |name| player.graveyard.add(sandbox_card(player, name)) }
      Array(spec[:battlefield]).each { |entry| sandbox_permanent(player, entry) }
    end

    def sandbox_permanent(player, entry)
      entry = { name: entry } if entry.is_a?(String)
      entry = entry.to_h.with_indifferent_access
      permanent = Magic::Permanent.resolve_spell(game: game, card: sandbox_card(player, entry[:name]))
      permanent.controlled_since_turn = 0
      permanent.tap! if entry[:tapped]
      (entry[:counters] || {}).each { |type, amount| amount.to_i.times { permanent.add_counter(type.to_s) } }
      permanent
    end

    def sandbox_card(player, name)
      card_class = Deck.card_class_for(name.to_s) || raise(ArgumentError, "Unknown card: #{name}")
      card_class.new(game: game, owner: player)
    end
  end
end
