# frozen_string_literal: true

# Google Chat lens over gog: primitives only (sibling of gmail.rb).
#   require_relative "chat"; Chat.messages("spaces/X", max: 5)
require_relative "gmail"

module Chat
  ME = ENV.fetch("CHAT_ME") { abort "set CHAT_ME=<your Chat display name>" }

  ChatMsg = Data.define(:id, :space, :thread, :sender, :text, :time) do
    def self.from_h(h)
      new(h["resource"], h["resource"].to_s[%r{\Aspaces/[^/]+}], h["thread"], h["sender"].to_s,
          h["text"].to_s, Time.parse(h["createTime"]))
    end

    def mine? = sender == ME
    def url = "https://chat.google.com/room/#{space.split('/').last}"
  end

  module_function

  def gog(*args) = Gmail.gog(*args, cmd: "chat")

  def spaces = gog("spaces", "list", "--all")["spaces"].to_a

  # Newest first. The API ignores --order in threaded spaces (results come
  # grouped by thread), so fetch a window and sort here.
  def messages(space, max: 20, window: 100)
    gog("messages", "list", space, "--max", [max, window].max, "--order", "createTime desc")
      .fetch("messages", []).map { ChatMsg.from_h(_1) }.sort_by(&:time).reverse.first(max)
  end
end
