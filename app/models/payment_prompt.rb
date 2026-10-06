# Asks the casting player whether to pay a spell's mana cost or pay life instead (Demon of Fate's Design). Like CastPrompt
# this is not an engine Choice: nothing is paid or put on the stack until the player has picked, and they may cancel.
class PaymentPrompt < ChoicePrompt
  Options = Struct.new(:choices)

  attr_reader :player, :card

  def initialize(game:, player:, card:)
    super(Options.new([]), game)
    @player = player
    @card = card
  end

  def controller = player

  def view
    { prompt: "Pay for #{card.name} with mana or with life?", kind: "options", cancelable: true,
      options: [{ id: "mana", label: "Pay mana" }, { id: "life", label: "Pay #{card.mana_value} life" }] }
  end

  def nothing_to_choose? = false

  def source_name = card.name

  # True when the player chose to pay life.
  def pay_life_for(answer)
    case Array(answer).first.to_s
    when "life" then true
    when "mana" then false
    else raise "Not a valid choice."
    end
  end

  def self.cancel?(answer)
    Array(answer).first.to_s == "cancel"
  end
end
