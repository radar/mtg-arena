require "digest"
require "fileutils"
require "json"

# Records a Table's game so it can be replayed: the seed that drives its shuffles and every call a player made, in order,
# with what Table answered and a digest of the game afterwards. A game that ends (or a call that raises) is written to
# tmp/games/<time>-<table id>.json, or to GAME_RECORD_DIR. See Table::Replay and script/replay.rb for playing one back.
#
# Table's ids for permanents and cards are object ids, which differ from run to run. Arguments that carry one are
# written as "@ref:<i|s>:<where>", where <where> is the object's position in the game ("p0.hand.3", "p1.battlefield.0",
# "stack.0"), and turned back into the replay's own object id when played back.
class Table
  module Recording
    RECORDED = %i[join play_land cast cycle tap_for_mana_by_hand untap_for_mana_by_hand activate activate_from_graveyard
                  pass_priority advance_step declare_attackers declare_blockers choose concede].freeze

    # The positions of a call's arguments (the uid is 0) that hold object ids. Counts in a +choose+ answer (damage to
    # assign, say) are numbers, so only strings are read as ids there; elsewhere an id may be a number too.
    ID_ARGUMENTS = {
      tap_for_mana_by_hand: [1], untap_for_mana_by_hand: [1], activate: [1], activate_from_graveyard: [1],
      declare_attackers: [1, 2], declare_blockers: [1], choose: [1]
    }.freeze
    STRINGS_ONLY = %i[choose].freeze

    REF = "@ref:".freeze
    FORMAT_VERSION = 1

    class UnknownReference < StandardError; end

    attr_reader :seed, :calls, :errors

    # Only the outermost call is recorded: when one of these methods calls another, the replay repeats the inner call
    # by itself.
    RECORDED.each do |name|
      define_method(name) do |*args|
        if @recording_call
          super(*args)
        else
          @mutex.synchronize do
            @recording_call = true
            Magic.with_random(@random) do
              encoded = encode_arguments(name, args)
              result = begin
                super(*args)
              rescue StandardError => e
                note_error(e)
                record_call(name, encoded, "raised #{e.class}: #{e.message}")
                save_record!(reason: "exception")
                raise
              end
              record_call(name, encoded, result)
              save_record!(reason: "game over") if over?
              result
            end
          ensure
            @recording_call = false
          end
        end
      end
    end

    # What Table answered, as plain data: nil (it worked), the reason it did not, or "ok" for an answer with more in it
    # (join returns the seat).
    def self.result_for_record(result)
      result.nil? || result.is_a?(String) ? result : "ok"
    end

    def encode_arguments(method, args)
      positions = ID_ARGUMENTS.fetch(method, [])
      return args.map { |arg| plain(arg) } if positions.empty?

      paths = object_paths
      args.each_with_index.map do |arg, index|
        positions.include?(index) ? encode_ids(arg, paths, strings_only: STRINGS_ONLY.include?(method)) : plain(arg)
      end
    end

    def decode_arguments(method, args)
      positions = ID_ARGUMENTS.fetch(method, [])
      return args if positions.empty?

      objects = objects_by_path
      args.each_with_index.map { |arg, index| positions.include?(index) ? decode_ids(arg, objects) : arg }
    end

    # Everything needed to find a bug in this game and replay it.
    def game_record(reason:)
      {
        "version" => FORMAT_VERSION,
        "table_id" => id,
        "seed" => @seed,
        "deck" => @deck.name,
        "reason" => reason,
        "saved_at" => Time.now.utc.iso8601,
        "over" => over?,
        "winner" => winner_name,
        "conceded" => !@conceded.nil?,
        "errors" => @errors,
        "calls" => @calls,
        "log" => @log.transcript,
        "final_state" => state_summary
      }
    end

    # Writes the record once per reason. Returns the path, or nil when nothing was written.
    def save_record!(reason:)
      directory = record_directory
      return unless @save_records && directory && @saved_reasons.add?(reason)

      FileUtils.mkdir_p(directory)
      path = File.join(directory, "#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{id.to_s.gsub(/[^\w-]/, '_')}-#{reason.tr(' ', '_')}.json")
      File.write(path, JSON.pretty_generate(game_record(reason: reason)))
      Rails.logger.info("Saved game record to #{path}")
      path
    rescue StandardError => e
      Rails.logger.error("Could not save game record: #{e.class}: #{e.message}")
      nil
    end

    # What the game looks like, by name, in a form that changes whenever a replay has gone a different way. Library
    # order is part of it, so a shuffle that came out differently shows up at once.
    def state_summary
      return unless started?

      turn = game.current_turn
      {
        "turn" => turn.number,
        "step" => turn.step,
        "active" => turn.active_player.name,
        "stack" => game.stack.cards.map(&:name),
        "players" => game.players.map do |player|
          {
            "name" => player.name,
            "life" => player.life,
            "hand" => player.hand.map(&:name),
            "battlefield" => player.permanents.map { |permanent| [permanent.name, permanent.tapped?] },
            "graveyard" => player.graveyard.map(&:name),
            "exile" => player.exile.map(&:name),
            "library" => player.library.map(&:name)
          }
        end
      }
    end

    private

    def record_directory
      ENV["GAME_RECORD_DIR"] || (Rails.root.join("tmp/games") unless Rails.env.test?)
    end

    def record_call(method, encoded, result)
      @calls << { "method" => method.to_s, "args" => encoded, "result" => Recording.result_for_record(result), "digest" => digest }
    end

    def digest
      summary = state_summary
      summary && Digest::SHA1.hexdigest(JSON.generate(summary))[0, 12]
    end

    def note_error(error)
      @errors << { "call" => @calls.size, "class" => error.class.name, "message" => error.message, "backtrace" => error.backtrace&.first(15) }
    end

    # Plain data that survives a trip through JSON.
    def plain(value)
      case value
      when Hash then value.to_h { |key, item| [key.to_s, plain(item)] }
      when Array then value.map { |item| plain(item) }
      when Symbol then value.to_s
      else value
      end
    end

    def encode_ids(value, paths, strings_only:)
      case value
      when Hash then value.to_h { |key, item| [encode_ids(key.to_s, paths, strings_only: true), encode_ids(item, paths, strings_only: strings_only)] }
      when Array then value.map { |item| encode_ids(item, paths, strings_only: strings_only) }
      when String
        (path = paths[value]) ? "#{REF}s:#{path}" : value
      when Integer
        (path = paths[value.to_s]) && !strings_only ? "#{REF}i:#{path}" : value
      else value
      end
    end

    def decode_ids(value, objects)
      case value
      when Hash then value.to_h { |key, item| [decode_ids(key, objects), decode_ids(item, objects)] }
      when Array then value.map { |item| decode_ids(item, objects) }
      when String
        return value unless value.start_with?(REF)

        kind, path = value.delete_prefix(REF).split(":", 2)
        object = objects.fetch(path) { raise UnknownReference, "nothing at #{path} to stand for #{value}" }
        kind == "i" ? object.object_id : object.object_id.to_s
      else value
      end
    end

    # "object id as a string" => where that object is in the game.
    def object_paths
      indexed_objects.to_h { |path, object| [object.object_id.to_s, path] }
    end

    def objects_by_path
      indexed_objects.to_h
    end

    # Every card and permanent an id could name, each with a path that is the same in a replay of the same game.
    def indexed_objects
      list = []
      game.players.each_with_index do |player, number|
        { "hand" => player.hand, "library" => player.library, "graveyard" => player.graveyard, "exile" => player.exile }.each do |zone, cards|
          cards.each_with_index { |card, index| list << ["p#{number}.#{zone}.#{index}", card] }
        end
        player.permanents.each_with_index { |permanent, index| list << ["p#{number}.battlefield.#{index}", permanent] }
      end
      game.exile.each_with_index { |card, index| list << ["exile.#{index}", card] }
      game.stack.map { |item| item }.each_with_index do |item, index|
        list << ["stack.#{index}", item]
        list << ["stack.#{index}.card", item.card] if item.respond_to?(:card)
      end
      list
    end
  end
end
