module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :uid

    def connect
      self.uid = cookies.encrypted[:arena_uid] || reject_unauthorized_connection
    end
  end
end
