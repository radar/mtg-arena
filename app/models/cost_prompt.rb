# Asks the activating player which permanents to sacrifice, or which card to discard, to pay an ability's cost
# (Nyxborn Behemoth, Bolas's Citadel, cycling). Like ActivationPrompt this is not an engine Choice: nothing is paid until
# the player has picked, and they may cancel instead.
class CostPrompt < ChoicePrompt
  Options = Struct.new(:choices)

  attr_reader :player, :permanent, :index, :count, :cost

  def initialize(game:, player:, permanent:, index:, cost:, choices:)
    super(Options.new(choices), game)
    @player = player
    @permanent = permanent
    @index = index
    @cost = cost
    @list = cost.is_a?(Magic::Costs::MultiTap) || cost.respond_to?(:amount)
    @count = cost.is_a?(Magic::Costs::MultiTap) ? cost.count : (cost.respond_to?(:amount) ? cost.amount : 1)
  end

  def controller = player

  def view
    verb = case cost
           when Magic::Costs::Discard then "discard"
           when Magic::Costs::MultiTap then "tap"
           else "sacrifice"
           end
    { prompt: "Choose #{count == 1 ? 'a card' : "#{count} cards"} to #{verb} for #{permanent.name}.",
      kind: "pick", min: count, max: count, cards: card_views(choice.choices.to_a), cancelable: true }
  end

  def nothing_to_choose? = false

  def source_name = permanent.name

  # The objects named by +answer+, shaped the way the cost's `pay` wants them (one, or an array for several).
  def payment_for(answer)
    ids = Array(answer).map(&:to_s)
    raise "Choose #{count} card#{'s' unless count == 1}." unless ids.size == count && ids.uniq.size == count

    picked = ids.map { |id| find(choice.choices.to_a, id) }
    @list ? picked : picked.first
  end

  def self.cancel?(answer)
    Array(answer).first.to_s == "cancel"
  end
end
