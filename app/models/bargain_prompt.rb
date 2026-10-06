# Asks the casting player whether to pay an optional additional cost of sacrificing a permanent (Bargain on Beseech the
# Mirror), and which one. Like CastPrompt this is not an engine Choice: nothing is paid or put on the stack until the
# player has answered, and they may cancel the cast instead. Answering with nothing picked casts without it.
class BargainPrompt < ChoicePrompt
  Options = Struct.new(:choices)

  attr_reader :draft

  def initialize(game:, draft:, choices:)
    super(Options.new(choices), game)
    @draft = draft
  end

  def player = draft.player

  def card = draft.card

  def controller = player

  def view
    { prompt: "Sacrifice a permanent to bargain for #{card.name}?", kind: "pick", min: 0, max: 1,
      cards: card_views(choice.choices), cancelable: true }
  end

  def nothing_to_choose? = false

  def source_name = card.name

  # The permanent picked, or nil when the player chose not to bargain.
  def permanent_for(answer)
    id = Array(answer).first
    id ? find(choice.choices, id) : nil
  end

  def self.cancel?(answer)
    Array(answer).first.to_s == "cancel"
  end
end
