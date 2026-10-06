# Asks the casting player for X in a spell's cost ({X}{G}: Thrive), from 0 to the most their lands can pay. Like CastPrompt
# this is not an engine Choice: nothing is paid until every question is answered, and the player may cancel the cast.
class XPrompt < ChoicePrompt
  Options = Struct.new(:choices)

  attr_reader :draft, :maximum

  # +allowed+: the values of X that can be chosen (all of 0..maximum when nil). A spell that targets "a creature with
  # mana value X" (Stolen by the Fae) only offers the X for which a creature exists.
  def initialize(game:, draft:, maximum:, allowed: nil)
    super(Options.new([]), game)
    @draft = draft
    @maximum = maximum
    @allowed = allowed || (0..maximum).to_a
  end

  def player = draft.player

  def card = draft.card

  def controller = player

  def view
    { prompt: "Choose X for #{card.name}.", kind: "options", cancelable: true,
      options: @allowed.map { |x| { id: x.to_s, label: "X = #{x}" } } }
  end

  def nothing_to_choose? = false

  def source_name = card.name

  def x_for(answer)
    x = Array(answer).first.to_s
    raise "Not a valid choice." unless x.match?(/\A\d+\z/) && @allowed.include?(x.to_i)

    x.to_i
  end

  def self.cancel?(answer)
    Array(answer).first.to_s == "cancel"
  end
end
