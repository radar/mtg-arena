# Asks the casting player which permanent to sacrifice for a spell's additional cost ("As an additional cost to cast this
# spell, sacrifice a creature": Village Rites, Harrow). Unlike a bargain this is not optional: a permanent must be picked,
# or the cast cancelled. Like CastPrompt this is not an engine Choice: nothing is paid until every question is answered.
class SacrificeCostPrompt < ChoicePrompt
  Options = Struct.new(:choices)

  attr_reader :draft, :cost

  def initialize(game:, draft:, cost:, choices:)
    super(Options.new(choices), game)
    @draft = draft
    @cost = cost
  end

  def player = draft.player

  def card = draft.card

  def controller = player

  def view
    { prompt: "Choose a permanent to sacrifice to cast #{card.name}.", kind: "pick", min: 1, max: 1,
      cards: card_views(choice.choices), cancelable: true }
  end

  def nothing_to_choose? = false

  def source_name = card.name

  def permanent_for(answer)
    find(choice.choices, Array(answer).first)
  end

  def self.cancel?(answer)
    Array(answer).first.to_s == "cancel"
  end
end
