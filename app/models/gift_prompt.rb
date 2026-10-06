# Asks whether to promise a gift ("Gift a card": Starfall Invocation). It costs nothing, so it is a kicker prompt without
# a price: answering "yes" sets the draft's kicker, which Table#pay_and_cast turns into Costs::Gift#pay.
class GiftPrompt < KickerPrompt
  def initialize(game:, draft:)
    super(game: game, draft: draft, cost: {})
  end

  def view
    { prompt: "Promise a gift with #{card.name}? (An opponent draws a card.)", kind: "options", cancelable: true,
      options: [{ id: "no", label: "No gift" }, { id: "yes", label: "Promise a gift" }] }
  end
end
