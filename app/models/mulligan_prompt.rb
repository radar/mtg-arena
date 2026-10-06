# The opening hand decision (London mulligan): keep, or shuffle the hand away and draw seven again. Having mulliganed N
# times, a player who keeps then puts N cards from their hand on the bottom of their library (the :bottom stage). Like
# CastPrompt this is not an engine Choice: it exists only in the Table, before the first turn begins.
class MulliganPrompt < ChoicePrompt
  Options = Struct.new(:choices)

  MAX_MULLIGANS = 6

  attr_reader :player, :taken, :stage

  def initialize(game:, player:, taken:, stage: :decide)
    super(Options.new(player.hand.cards.map(&:itself)), game)
    @player = player
    @taken = taken
    @stage = stage
  end

  def controller = player

  def view
    return bottom_view if stage == :bottom

    options = [{ id: "keep", label: "Keep" }]
    options << { id: "mulligan", label: "Mulligan" } if taken < MAX_MULLIGANS
    { prompt: taken.zero? ? "Keep this hand?" : "Keep this hand? (mulligan #{taken})", kind: "options", options: options }
  end

  def nothing_to_choose? = false

  def source_name = nil

  # "keep" or "mulligan".
  def decision(answer)
    answer = Array(answer).first.to_s
    raise "Not a valid choice." unless %w[keep mulligan].include?(answer)

    answer
  end

  # The cards chosen to go on the bottom.
  def cards_for(answer)
    ids = Array(answer).map(&:to_s)
    raise "Choose #{taken} card#{'s' unless taken == 1} to put on the bottom." unless ids.size == taken && ids.uniq.size == taken

    ids.map { |id| find(choice.choices, id) }
  end

  private

  def bottom_view
    { prompt: "Put #{taken} card#{'s' unless taken == 1} from your hand on the bottom of your library.",
      kind: "pick", min: taken, max: taken, cards: card_views(choice.choices) }
  end
end
