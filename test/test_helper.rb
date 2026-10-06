ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# A new game opens with each player deciding on their opening hand. Most tests want to start from the first turn, so
# both players keep (see Table#choose) unless a test turns this off with `Table.auto_keep = false`.
module AutoKeepOpeningHands
  mattr_accessor :enabled, default: true

  def join(uid, deck_name = nil)
    seat = super
    if AutoKeepOpeningHands.enabled && seats.size == Table::SEATS
      Table::SEATS.times { seats.each { |s| choose(s.uid, "keep") if view_for(s.uid).dig(:choice, :chooser) } }
    end
    seat
  end
end
Table.prepend(AutoKeepOpeningHands)

module ActiveSupport
  class TestCase
    # Not run in parallel: there is no database (Rails would try to set one up per worker once there are 50 tests).

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
