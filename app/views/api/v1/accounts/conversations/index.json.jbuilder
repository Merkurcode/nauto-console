json.data do
  json.meta do
    json.mine_count @conversations_count[:mine_count]
    json.assigned_count @conversations_count[:assigned_count]
    json.unassigned_count @conversations_count[:unassigned_count]
    json.all_count @conversations_count[:all_count]
    json.missing_pages @conversations_count[:missing_pages]
  end
  json.payload do
    preloaded_last_messages = Conversation.preload_last_messages(@conversations)
    preloaded_last_non_activity_messages = Conversation.preload_last_non_activity_messages(@conversations)
    contact_ids = @conversations.map(&:contact_id)
    preloaded_last_appointments = Contact.preload_last_appointments(contact_ids)
    preloaded_last_conversations = Contact.preload_last_conversations(contact_ids)
    json.array! @conversations do |conversation|
      json.partial! 'api/v1/conversations/partials/conversation', formats: [:json], conversation: conversation,
                                                                  preloaded_last_messages: preloaded_last_messages,
                                                                  preloaded_last_non_activity_messages: preloaded_last_non_activity_messages,
                                                                  preloaded_last_appointments: preloaded_last_appointments,
                                                                  preloaded_last_conversations: preloaded_last_conversations
    end
  end
end
