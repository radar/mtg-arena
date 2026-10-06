# Asks whether to pay a kicker cost paid with mana ("Kicker {4}": Vastwood Surge). Like CastPrompt this is not an engine
# Choice: nothing is paid until every question is answered, and the player may cancel the cast.
class KickerPrompt < ChoicePrompt
  Options = Struct.new(:choices)

  attr_reader :draft

  def initialize(game:, draft:, cost:)
    super(Options.new([]), game)
    @draft = draft
    @cost = cost
  end

  def player = draft.player

  def card = draft.card

  def controller = player

  def view
    { prompt: "Kick #{card.name}?", kind: "options", cancelable: true,
      options: [{ id: "no", label: "Don't kick" }, { id: "yes", label: "Kick (#{cost_text})" }] }
  end

  def nothing_to_choose? = false

  def source_name = card.name

  # True to kick the spell.
  def kicked?(answer)
    case Array(answer).first.to_s
    when "yes" then true
    when "no" then false
    else raise "Not a valid choice."
    end
  end

  def self.cancel?(answer)
    Array(answer).first.to_s == "cancel"
  end

  private

  def cost_text
    @cost.map { |color, amount| color == :generic ? "{#{amount}}" : "{#{color.to_s[0].upcase}}" * amount }.join
  end
end
