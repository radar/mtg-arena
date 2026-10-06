# Plays a whole game through Table's public API, the way two people clicking in the browser would: attack with
# everything, block when it can, take every land and spell on offer, say yes to every "may". Used by
# script/simulate.rb and the full-game test to shake out engine and Table bugs.
class Bot
  class Stuck < StandardError; end

  attr_reader :decisions

  def initialize(table, uids: %w[p1 p2], log: ->(_message) {}, max_decisions: 3000)
    @table = table
    @uids = uids
    @log = log
    @max = max_decisions
    @decisions = 0
    @activated = []
  end

  # Plays until the game is over. Raises Stuck with the offending state if a player's action is refused or nobody can act.
  def play
    last_turn = nil
    until table.over?
      @decisions += 1
      raise Stuck, "no result after #{@max} decisions" if @decisions > @max

      # Building a view is the slow part (it rehearses payments on game copies), so the acting player's is kept.
      view = nil
      uid = uids.find { |u| (view = table.view_for(u))[:can_act] }
      raise Stuck, "nobody can act: #{view.except(:you, :opponent).inspect}" unless uid
      turn = [view[:turn][:number], view[:turn][:active]]
      if turn != last_turn
        last_turn = turn
        log.call("-- turn #{turn.first} #{turn.last}  life #{view[:you][:life]}-#{view[:opponent][:life]}")
      end

      error = act(uid, view)
      raise Stuck, "#{uid} #{view[:turn][:step]}: #{error}" if error
    end
    self
  end

  private

  attr_reader :table, :uids, :log

  def act(uid, view)
    me = view[:you]
    step = view[:turn][:step]
    if view[:choice]
      answer_choice(uid, view)
    elsif view[:priority]
      # Responds with a spell when it has one it can cast; otherwise lets the stack resolve.
      index = me[:hand].index { |c| c[:castable] }
      if index
        log.call("  #{me[:name]} responds with #{me[:hand][index][:name]}")
        table.cast(uid, index)
      else
        log.call("  #{me[:name]} passes priority")
        table.pass_priority(uid)
      end
    elsif step == "declare_attackers"
      attackers = me[:battlefield].select { |p| p[:can_attack] }
      log.call("  #{me[:name]} attacks with #{attackers.map { |p| "#{p[:name]} #{p[:power]}/#{p[:toughness]}" }.join(', ')}")
      walker = view[:opponent][:battlefield].find { |p| p[:planeswalker] }
      table.declare_attackers(uid, attackers.map { |p| p[:id] }, walker ? attackers.to_h { |p| [p[:id], walker[:id]] } : {})
    elsif step == "declare_blockers"
      attackers = view[:opponent][:battlefield].select { |p| p[:attacking] }
      blockers = me[:battlefield].select { |p| p[:can_block] }
      # Spare blockers double up on the attackers, which also exercises damage assignment order.
      pairs = attackers.empty? ? [] : blockers.each_with_index.map { |b, i| [b[:id], attackers[i % attackers.size][:id]] }
      log.call("  #{me[:name]} blocks #{pairs.size} of #{attackers.size}")
      # An illegal set of blocks (menace, flying...) is refused as a whole: fall back to no blocks, like a person would.
      table.declare_blockers(uid, pairs) && table.declare_blockers(uid, [])
    elsif view[:can_play_land] && (index = me[:hand].index { |c| c[:land] })
      log.call("  #{me[:name]} plays #{me[:hand][index][:name]}")
      table.play_land(uid, index)
    elsif me[:library_top]&.dig(:playable_land)
      log.call("  #{me[:name]} plays #{me[:library_top][:name]} from the top of their library")
      table.play_land(uid, 0, "library")
    elsif me[:library_top]&.dig(:castable)
      log.call("  #{me[:name]} casts #{me[:library_top][:name]} from the top of their library")
      table.cast(uid, 0, "library")
    elsif (index = me[:hand].index { |c| c[:castable] })
      log.call("  #{me[:name]} casts #{me[:hand][index][:name]}")
      table.cast(uid, index)
    elsif (index = me[:hand].index { |c| c[:cyclable] })
      log.call("  #{me[:name]} cycles #{me[:hand][index][:name]}")
      table.cycle(uid, index)
    elsif (ability = next_ability(view))
      log.call("  #{me[:name]} activates #{ability[:name]}: #{ability[:label]}")
      table.activate(uid, ability[:id], ability[:index])
    else
      table.advance_step(uid)
    end
  end

  # Each ability is used at most once per turn, so a repeatable one cannot keep the bot busy forever.
  def next_ability(view)
    turn = view[:turn][:number]
    view[:you][:battlefield].each do |permanent|
      permanent[:abilities].each do |ability|
        key = [turn, permanent[:id], ability[:index]]
        next if !ability[:activatable] || @activated.include?(key)

        @activated << key
        return { id: permanent[:id], index: ability[:index], name: permanent[:name], label: ability[:label] }
      end
    end
    nil
  end

  def answer_choice(uid, view)
    choice = view[:choice]
    log.call("  #{view[:you][:name]}: #{choice[:prompt]} (#{choice[:kind]})")
    case choice[:kind]
    when "may" then table.choose(uid, "yes")
    when "options" then table.choose(uid, choice[:options].first[:id])
    when "confirm" then table.choose(uid, "ok")
    when "target"
      mine = view[:you][:name]
      pick = choice[:targets].find { |t| t[:label] == view[:opponent][:name] } ||
        choice[:targets].find { |t| !t[:label].include?("(#{mine})") } || choice[:targets].first
      table.choose(uid, pick[:id])
    when "assign" then table.choose(uid, choice[:rows].to_h { |row| [row[:id], row[:value]] })
    when "modes" then table.choose(uid, choice[:options].first(choice[:min]).map { |o| o[:id] })
    when "pick"
      ids = choice[:cards].first(choice[:max]).map { |c| c[:id] }
      error = table.choose(uid, ids)
      # A set the card refuses (Myriad Landscape's two lands must share a type): take fewer, as a person would.
      error && ids.size > [choice[:min], 1].max ? table.choose(uid, ids.first([choice[:min], 1].max)) : error
    when "sort" then table.choose(uid, { choice[:destinations].first => choice[:cards].map { |c| c[:id] } })
    else raise Stuck, "unsupported choice #{choice.inspect}"
    end
  end
end
