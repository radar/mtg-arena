# Asks the casting player for one target of a spell (an aura, a removal spell, one of the targets of a multi-target spell
# or of a mode). Like CastPrompt and ActivationPrompt this is not an engine Choice: nothing is paid or put on the stack
# until every target is picked, and the player may cancel.
class SpellTargetPrompt < ChoicePrompt
  Options = Struct.new(:choices)

  attr_reader :draft, :slot

  def initialize(game:, draft:, slot:)
    super(Options.new(draft.choices_for(slot)), game)
    @draft = draft
    @slot = slot
  end

  def player = draft.player

  def card = draft.card

  def controller = player

  def view
    targeted_view({ prompt: prompt_text }).merge(cancelable: true)
  end

  def nothing_to_choose? = false

  def source_name = card.name

  def target_for(answer)
    find(choice.choices, Array(answer).first)
  end

  def self.cancel?(answer)
    Array(answer).first.to_s == "cancel"
  end

  private

  def prompt_text
    total = draft.total_slots(slot.owner)
    text = "Choose a target for #{card.name}"
    text += " (#{slot.index + 1} of #{total})" if total > 1
    text += " (#{slot.owner.name.demodulize.titleize})" unless slot.owner == :spell
    "#{text}."
  end
end
