# What a player has decided so far while casting a spell, before anything is paid or put on the stack: whether they are
# paying life, what (if anything) they sacrifice to bargain, which modes, and each target. Table asks for the next missing
# piece with a prompt until nothing is missing, then builds the Magic::Actions::Cast from it.
class CastDraft
  # One target to pick. +owner+ is :spell, or the mode class the target belongs to; +index+ says which of that owner's
  # targets it is (a multi-target spell has several); +choices+ are the legal ones.
  Slot = Struct.new(:owner, :index, :choices, :distinct)

  attr_reader :player, :card, :pay_life, :picks, :sacrifices
  attr_accessor :bargain, :modes, :slots, :x, :kicker

  def initialize(player:, card:, pay_life:)
    @player = player
    @card = card
    @pay_life = pay_life
    @bargain = :ask # until asked: then the permanent sacrificed, or nil
    @modes = nil    # until asked: then the chosen mode classes
    @slots = nil    # until worked out
    @x = nil        # until asked, for a spell with {X} in its cost: then the number chosen
    @kicker = :ask  # until asked, for a spell that can be kicked: then true, false, or the permanent sacrificed
    @sacrifices = [] # what was picked to pay each additional cost that sacrifices a permanent, in order
    @picks = Hash.new { |hash, owner| hash[owner] = [] }
  end

  def next_slot
    slots.find { |slot| picks[slot.owner].size <= slot.index }
  end

  def pick(slot, target)
    picks[slot.owner] << target
  end

  # The slot's choices, less what its owner already picked when the targets must differ.
  def choices_for(slot)
    slot.distinct ? slot.choices.reject { |choice| picks[slot.owner].include?(choice) } : slot.choices
  end

  def total_slots(owner)
    slots.count { |slot| slot.owner == owner }
  end
end
