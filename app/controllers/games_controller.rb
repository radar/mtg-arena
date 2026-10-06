class GamesController < ApplicationController
  before_action :ensure_uid

  def show
    @game_id = params[:id]
    # The deck the game is played with, if it is not already under way: /games/some-id?deck=elves
    @deck = params[:deck].to_s
  end

  private

  def ensure_uid
    cookies.encrypted[:arena_uid] ||= { value: SecureRandom.uuid, expires: 1.year.from_now }
  end
end
