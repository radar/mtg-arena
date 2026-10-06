# After the blockers of one attacker are ordered, its controller divides its combat damage among them (rule 510.1): lethal
# damage to each before the next, and the rest wherever they like. A trampler may also assign damage to the player or
# planeswalker it attacks, once everything blocking it has lethal. The engine checks the division
# (CombatPhase#assign_combat_damage); this only asks for it. Like CastPrompt this is not an engine Choice.
class DamagePrompt < ChoicePrompt
  Options = Struct.new(:choices)

  attr_reader :player, :attack

  def initialize(game:, player:, attack:)
    super(Options.new(attack.blockers.to_a), game)
    @player = player
    @attack = attack
  end

  def controller = player

  def total = attack.attacker.combat_damage_amount

  def view
    { prompt: "Divide #{total} combat damage from #{attack.attacker.name} among its blockers, in order.", kind: "assign",
      total: total, rows: rows }
  end

  def nothing_to_choose? = false

  def source_name = attack.attacker.name

  # { creature or player => damage } from +answer+ ({ id => amount }); raises when it does not add up to the damage dealt.
  def assignment_for(answer)
    amounts = answer.to_h.stringify_keys.transform_values(&:to_i)
    raise "Assign all #{total} damage (you assigned #{amounts.values.sum})." unless amounts.values.sum == total

    check_order!(amounts)
    targets = choice.choices.index_by { |blocker| blocker.object_id.to_s }
    targets["player"] = attack.target if trample?
    amounts.reject { |_, amount| amount.zero? }.to_h do |id, amount|
      [targets.fetch(id) { raise "Not a valid choice." }, amount]
    end
  end

  private

  def trample? = attack.attacker.trample?

  # Rule 510.1c: damage may only go to a blocker once every blocker before it has been assigned lethal damage.
  def check_order!(amounts)
    blockers = choice.choices
    blockers.each_with_index do |blocker, index|
      later = blockers.drop(index + 1).map { |other| amounts.fetch(other.object_id.to_s, 0) } + [amounts.fetch("player", 0)]
      next if later.sum.zero?
      next if amounts.fetch(blocker.object_id.to_s, 0) >= lethal_to(blocker)

      raise "#{blocker.name} must be assigned lethal damage (#{lethal_to(blocker)}) before damage goes to the next."
    end
  end

  # One row per blocker, in damage order, each with the damage that is lethal to it; the default fills them in order.
  def rows
    remaining = total
    list = choice.choices.map do |blocker|
      lethal = lethal_to(blocker)
      value = [lethal, remaining].min
      remaining -= value
      { id: blocker.object_id.to_s, label: "#{blocker.name} #{blocker.power}/#{blocker.toughness - blocker.damage}", lethal: lethal, value: value }
    end
    list.last[:value] += remaining unless trample?
    if trample?
      list << { id: "player", label: attack.target.name, lethal: 0, value: remaining }
    end
    list
  end

  def lethal_to(blocker)
    attack.attacker.deathtouch? ? 1 : [blocker.toughness - blocker.damage, 1].max
  end
end
