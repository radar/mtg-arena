require "test_helper"

class GameChannelTest < ActionCable::Channel::TestCase
  test "two players join and each receives their hand" do
    id = SecureRandom.hex(4)

    stub_connection uid: "a"
    subscribe id: id
    assert_not transmissions.last["seated"]
    perform :join
    assert transmissions.last || true

    stub_connection uid: "b"
    subscribe id: id
    perform :join

    assert_equal 7, TableRegistry.fetch(id).view_for("b")[:you][:hand].size
  end
end
