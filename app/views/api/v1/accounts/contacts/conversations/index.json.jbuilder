json.payload do
  preloaded_last_messages = Conversation.preload_last_messages(@conversations)
  preloaded_last_non_activity_messages = Conversation.preload_last_non_activity_messages(@conversations)
  json.array! @conversations do |conversation|
    json.partial! 'api/v1/conversations/partials/conversation', formats: [:json], conversation: conversation,
                                                                preloaded_last_messages: preloaded_last_messages,
                                                                preloaded_last_non_activity_messages: preloaded_last_non_activity_messages
  end
end
