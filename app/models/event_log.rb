# Listens to a Magic::Game's events and keeps a short, public, human-readable log of what happened.
# Subscribed as an event listener and as the game's stack observer (see Table#start_game!), so it sees events from
# every action, trigger and combat, and knows which spell, ability or choice an event happened under.
#
# Entries caused by something earlier are linked to it: playing Scoured Barrens is one entry, and the life it gains is
# a child of that entry (parent_id, depth, and the source in `via`). Each entry has at most one parent.
class EventLog
  MAX_ENTRIES = 150

  Entry = Struct.new(:id, :kind, :text, :parent_id, :depth, :via, keyword_init: true)

  def initialize
    @entries = []
    @next_id = 0
    @context = []     # what is resolving right now: [{ parent:, via: }], innermost last
    @cause = {}       # stack item / choice (object_id) => id of the entry that was newest when it was added
    @spell_entry = {} # spell card (object_id) => id of its "cast" entry
    @ability_entry = {} # activated ability (object_id) => id of its "activated" entry
    @depths = {}
    @transcript = [] # every entry, uncapped, for the game record (see Table::Recording)
  end

  attr_reader :transcript

  # Stack observer: remember what an item was caused by when it appears...
  def added(item)
    @cause[item.object_id] = @entries.last&.id
  end

  # ...and file everything that happens while it resolves under that cause.
  def resolving(item)
    @context.push(parent: parent_for(item), via: source_name(item))
    yield
  ensure
    @context.pop
  end

  def entries
    @entries.map(&:to_h)
  end

  def turn(number, player_name)
    add(:turn, "Turn #{number} — #{player_name}")
  end

  # Note, under whatever caused +item+, that a choice was skipped because there was nothing to choose from.
  def skipped(item, text)
    resolving(item) { add(:skip, text) }
  end

  def add(kind, text)
    context = @context.last
    parent_id = context && context[:parent]
    depth = parent_id ? @depths.fetch(parent_id, 0) + 1 : 0
    via = context && context[:via]
    via = nil if via && text.include?(via)

    entry = Entry.new(id: (@next_id += 1), kind: kind, text: text, parent_id: parent_id, depth: depth, via: via)
    @depths[entry.id] = depth
    @entries << entry
    @transcript << entry.to_h
    @entries.shift while @entries.size > MAX_ENTRIES
    entry
  end

  def receive_event(event)
    case event
    when Magic::Events::SpellCast then @spell_entry[event.spell.object_id] = add(:spell, "#{event.player.name} cast #{event.spell.name}").id
    when Magic::Events::EnteredTheBattlefield then entered(event.permanent)
    when Magic::Events::AbilityActivated then activated(event)
    when Magic::Events::AttackDeclared then add(:combat, "#{event.attack.attacker.name} attacks #{target_name(event.attack.target)}")
    when Magic::Events::CreatureBlocked then add(:combat, "#{event.blocker.name} blocks #{event.attacker.name}")
    when Magic::Events::DamageDealt then add(:damage, "#{event.source.name} deals #{event.damage} damage to #{target_name(event.target)}") if event.damage.to_i.positive?
    when Magic::Events::CreatureDied then add(:death, "#{event.permanent.name} dies")
    when Magic::Events::PermanentSacrificed then add(:death, "#{event.permanent.controller.name} sacrificed #{event.permanent.name}")
    when Magic::Events::LifeGain then add(:life, "#{event.player.name} gains #{event.life} life") if event.life.to_i.positive?
    when Magic::Events::LifeLoss then add(:life, "#{event.player.name} loses #{event.life} life") if event.life.to_i.positive?
    when Magic::Events::CardDraw then add(:draw, "#{event.player.name} draws a card")
    when Magic::Events::Scry then add(:info, "#{event.player.name} scries #{event.top + event.bottom}")
    when Magic::Events::CounterAddedToPermanent then add(:info, "#{event.amount} #{event.counter_type} counter#{'s' unless event.amount == 1} on #{event.target.name}")
    when Magic::Events::PlayerLost then add(:life, "#{event.player.name} loses the game")
    end
  end

  private

  def entered(permanent)
    add(:enter, permanent.card.land? ? "#{permanent.controller.name} played #{permanent.name}" : "#{permanent.name} enters the battlefield (#{permanent.controller.name})")
  end

  # Mana abilities fire constantly while paying for spells, so they stay out of the log.
  def activated(event)
    return if event.ability.is_a?(Magic::ManaAbility)

    @ability_entry[event.ability.object_id] = add(:ability, "#{event.player.name} activated #{event.ability.source.name}").id
  end

  def parent_for(item)
    if item.respond_to?(:card) && @spell_entry.key?(item.card.object_id)
      @spell_entry[item.card.object_id]
    elsif item.respond_to?(:ability) && @ability_entry.key?(item.ability.object_id)
      @ability_entry[item.ability.object_id]
    else
      @cause[item.object_id]
    end
  end

  # The card behind a spell, ability, trigger or choice, for the "via" label on what it causes.
  def source_name(item)
    source = if item.respond_to?(:card) then item.card
    elsif item.respond_to?(:ability) then item.ability.source
    elsif item.respond_to?(:actor) then item.actor
    end
    source.name if source.respond_to?(:name)
  end

  def target_name(target)
    target.respond_to?(:name) ? target.name : target.to_s
  end
end
