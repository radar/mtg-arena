# When several creatures block one attacker, its controller orders them (rule 509.2): combat damage goes to the first
# until it is lethal, then the next, and so on. Asked one blocker at a time, "who is first?", until one is left. Like
# CastPrompt this is not an engine Choice.
class BlockerOrderPrompt < ChoicePrompt
  Options = Struct.new(:choices)

  attr_reader :player, :attack, :ordered

  def initialize(game:, player:, attack:, ordered: [])
    super(Options.new(attack.blockers.reject { |blocker| ordered.include?(blocker) }), game)
    @player = player
    @attack = attack
    @ordered = ordered
  end

  def controller = player

  def view
    position = ordered.empty? ? "first" : "next"
    { prompt: "#{attack.attacker.name} is blocked by several creatures. Which one takes damage #{position}?", kind: "options",
      options: choice.choices.map { |blocker| { id: blocker.object_id.to_s, label: label(blocker) } } }
  end

  def nothing_to_choose? = false

  def source_name = attack.attacker.name

  def blocker_for(answer)
    id = Array(answer).first.to_s
    choice.choices.find { |blocker| blocker.object_id.to_s == id } || raise("Not a valid choice.")
  end

  private

  def label(blocker)
    "#{blocker.name} #{blocker.power}/#{blocker.toughness - blocker.damage}"
  end
end
