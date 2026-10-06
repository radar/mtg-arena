# Asks the acting player for the target of an ability they are activating (an equip, a planeswalker's -3). Unlike a
# Magic::Choice this is not on the engine's stack: the ability is only activated, and its costs paid, once the player
# has picked every target, and the player may cancel instead. An ability with several targets (Calix's -3) is asked one
# target at a time: +lists+ holds the legal choices for each, +chosen+ the targets picked so far.
class ActivationPrompt < ChoicePrompt
  Options = Struct.new(:choices)

  attr_reader :player, :permanent, :index, :lists, :chosen

  def initialize(game:, player:, permanent:, index:, choices:, lists: [choices], chosen: [])
    super(Options.new(choices), game)
    @player = player
    @permanent = permanent
    @index = index
    @lists = lists
    @chosen = chosen
  end

  def controller = player

  def view
    targeted_view({ prompt: prompt_text }).merge(cancelable: true)
  end

  def nothing_to_choose? = false

  def target_for(answer)
    find(choice.choices, Array(answer).first)
  end

  # The choices for the next target, or nil once every target has been picked (+target+ being the one just picked).
  def choices_after(target)
    following = lists[chosen.size + 1]
    following&.reject { |option| option.equal?(target) || chosen.include?(option) }
  end

  def self.cancel?(answer)
    Array(answer).first.to_s == "cancel"
  end

  private

  def prompt_text
    text = "Choose a target for #{permanent.name}"
    text += " (#{chosen.size + 1} of #{lists.size})" if lists.size > 1
    "#{text}."
  end
end
