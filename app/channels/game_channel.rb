class GameChannel < ApplicationCable::Channel
  def subscribed
    @table = TableRegistry.fetch(params[:id].to_s, deck: params[:deck].to_s)
    stream_from stream_name(uid)
    transmit(@table.view_for(uid))
  end

  def join(data = {})
    broadcast_views if @table.join(uid, data["deck"])
  end

  def play_land(data)
    respond_to_action @table.play_land(uid, data["index"], data["zone"] || "hand", data["face"] || "front")
  end

  def cast(data)
    respond_to_action @table.cast(uid, data["index"], data["zone"] || "hand")
  end

  def activate_graveyard(data)
    respond_to_action @table.activate_from_graveyard(uid, data["id"], data["index"])
  end

  def cycle(data)
    respond_to_action @table.cycle(uid, data["index"])
  end

  def declare_attackers(data)
    respond_to_action @table.declare_attackers(uid, data["ids"], data["targets"] || {})
  end

  def declare_blockers(data)
    respond_to_action @table.declare_blockers(uid, data["pairs"])
  end

  def choose(data)
    respond_to_action @table.choose(uid, data["answer"])
  end

  def activate(data)
    respond_to_action @table.activate(uid, data["id"], data["index"])
  end

  def tap_for_mana(data)
    respond_to_action @table.tap_for_mana_by_hand(uid, data["id"], data["color"])
  end

  def untap_for_mana(data)
    respond_to_action @table.untap_for_mana_by_hand(uid, data["id"])
  end

  def concede
    respond_to_action @table.concede(uid)
  end

  def pass_priority
    respond_to_action @table.pass_priority(uid)
  end

  def advance_step
    respond_to_action @table.advance_step(uid)
  end

  private

  def respond_to_action(error)
    return transmit({ error: error }) if error

    broadcast_views
  end

  # Everyone's view can change, so refresh each seat.
  def broadcast_views
    @table.seats.each { |seat| ActionCable.server.broadcast(stream_name(seat.uid), @table.view_for(seat.uid)) }
  end

  def stream_name(uid)
    "game:#{@table.id}:#{uid}"
  end
end
