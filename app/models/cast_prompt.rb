# Asks the casting player which modes of a modal spell to cast it with ("Choose one or more —", Farewell). Like
# ActivationPrompt this is not an engine Choice: nothing is paid or put on the stack until the modes are picked, and the
# player may cancel instead. Only modes that need no target are offered (see Table#modal_supported?).
class CastPrompt < ChoicePrompt
  Options = Struct.new(:choices)

  MODE_LABELS = {
    "Magic::Cards::Farewell::ExileArtifacts" => "Exile all artifacts",
    "Magic::Cards::Farewell::ExileCreatures" => "Exile all creatures",
    "Magic::Cards::Farewell::ExileEnchantments" => "Exile all enchantments",
    "Magic::Cards::Farewell::ExileGraveyards" => "Exile all graveyards"
  }.freeze

  attr_reader :draft

  def initialize(game:, draft:)
    super(Options.new([]), game)
    @draft = draft
  end

  def player = draft.player

  def card = draft.card

  def controller = player

  def view
    { prompt: heading, kind: "modes", min: min, max: max, cancelable: true,
      options: available.map { |mode| { id: mode.name, label: label(mode) } } }
  end

  def nothing_to_choose? = false

  def source_name = card.name

  # The Cast action to put the chosen modes on.
  def cast_action
    x = card.cost.cost.key?(:x) ? draft.x.to_i : nil
    Magic::Actions::Cast.new(game: game, player: player, card: card, pay_life: draft.pay_life, value_for_x: x)
  end

  # The mode classes named by +answer+ (ids from #view); raises when the number is not allowed.
  def modes_for(answer)
    ids = Array(answer).map(&:to_s)
    modes = available.select { |mode| ids.include?(mode.name) }
    raise "Choose #{count_text} for #{card.name}." unless modes.size == ids.size && (min..max).cover?(modes.size)

    modes
  end

  def self.cancel?(answer)
    Array(answer).first.to_s == "cancel"
  end

  private

  def available
    cast_action.available_modes
  end

  def min
    [cast_action.min_modes, 1].max
  end

  def max
    cast_action.max_modes || available.size
  end

  def label(mode)
    MODE_LABELS.fetch(mode.name) { mode.name.demodulize.titleize }
  end

  def heading
    "Choose #{count_text} for #{card.name}."
  end

  def count_text
    return "#{min} mode#{'s' unless min == 1}" if min == max

    "#{min} to #{max} modes"
  end
end
