# frozen_string_literal: true

class AgentBots::ReengagementService
  def initialize(reengagement)
    @reengagement   = reengagement
    @conversation   = reengagement.conversation
    @agent_bot      = reengagement.agent_bot
    @contact        = @conversation.contact
  end

  def execute
    return suppress_for_sequence if active_sequence?
    return cancel(:cancelled_reply)  if should_stop_on_resolved?
    return cancel(:cancelled_reply)  if should_stop_on_agent_assigned?
    return cancel(:cancelled_reply)  if client_replied_since_trigger? && @reengagement.stop_on_any_reply?
    return cancel_keyword(matched_keyword) if detect_stop_keyword

    dispatch_message
    completed = @reengagement.advance!

    Rails.logger.info(
      "ReengagementService: fired attempt #{@reengagement.current_attempt} " \
      "for conversation #{@conversation.id} (completed: #{completed})"
    )
  end

  private

  # ─── Stop condition checks ───────────────────────────────────────────

  def active_sequence?
    ConversationFollowUp.exists?(conversation_id: @conversation.id, status: 'active')
  end

  def should_stop_on_resolved?
    @reengagement.stop_on_resolved? && @conversation.resolved?
  end

  def should_stop_on_agent_assigned?
    @reengagement.stop_on_agent_assigned? && @conversation.assignee_id.present?
  end

  def client_replied_since_trigger?
    @conversation.messages
                 .where(message_type: :incoming)
                 .exists?(['created_at > ?', @reengagement.trigger_started_at])
  end

  def detect_stop_keyword
    phrases, case_insensitive = @reengagement.stop_keywords
    return nil if phrases.blank?

    last_incoming = @conversation.messages
                                 .where(message_type: :incoming)
                                 .where('created_at > ?', @reengagement.trigger_started_at)
                                 .order(created_at: :desc)
                                 .first

    return nil if last_incoming&.content.blank?

    text = case_insensitive ? last_incoming.content.downcase : last_incoming.content

    phrases.find do |phrase|
      needle = case_insensitive ? phrase.downcase : phrase
      text.include?(needle)
    end
  end

  # ─── Actions ─────────────────────────────────────────────────────────

  def suppress_for_sequence
    sequence_id = ConversationFollowUp
                  .where(conversation_id: @conversation.id, status: 'active')
                  .pick(:lead_follow_up_sequence_id)
    @reengagement.suppress!(sequence_id: sequence_id)
  end

  def cancel(status_symbol)
    @reengagement.cancel!(reason: status_symbol.to_s)
  end

  def cancel_keyword(phrase)
    @reengagement.cancel!(
      reason: 'cancelled_keyword',
      extra_meta: { 'matched_keyword' => phrase }
    )
  end

  def dispatch_message
    if whatsapp_channel? && !conversation_window_open? && reengagement_template_approved?
      send_reengagement_template
    else
      fire_webhook
    end
  end

  def whatsapp_channel?
    @conversation.inbox.channel_type == 'Channel::Whatsapp'
  end

  def conversation_window_open?
    @conversation.can_reply?
  end

  def reengagement_template_approved?
    template_config = @conversation.inbox.reengagement_config&.dig('template')
    return false unless template_config

    template_name = template_config['name']
    return false unless template_name

    status_result = @conversation.inbox.channel.provider_service.get_template_status(template_name)
    status_result[:success] && status_result[:template][:status] == 'APPROVED'
  rescue StandardError => e
    Rails.logger.error "ReengagementService: error checking template status for conversation #{@conversation.id}: #{e.message}"
    false
  end

  def send_reengagement_template
    config       = @conversation.inbox.reengagement_config
    contact_name = @contact.name.presence || @contact.phone_number
    message      = build_reengagement_message(config, contact_name)
    message_id   = @conversation.inbox.channel.provider_service.send_template(
      @conversation.contact_inbox.source_id,
      build_template_info(config, contact_name),
      message
    )
    message.update!(source_id: message_id) if message_id.present?
  rescue StandardError => e
    Rails.logger.error "ReengagementService: failed to send template for conversation #{@conversation.id}: #{e.message}"
  end

  def build_template_info(config, contact_name)
    {
      name: config.dig('template', 'name'),
      lang_code: config['language'] || 'es_MX',
      parameters: [{ type: 'body', parameters: [{ type: 'text', text: contact_name }] }]
    }
  end

  def build_reengagement_message(config, contact_name)
    @conversation.messages.build(
      account: @conversation.account,
      inbox: @conversation.inbox,
      message_type: :outgoing,
      content: (config['message'] || '').gsub('{{1}}', contact_name),
      content_type: :text
    )
  end

  def fire_webhook
    config   = @reengagement.reengagement_config
    attempts = config['attempts'] || []

    reactivation_count = @reengagement.metadata&.dig('reactivation_count').to_i
    idempotency_key = Digest::SHA256.hexdigest(
      "reengagement-#{@reengagement.id}-attempt-#{@reengagement.current_attempt}-reactivation-#{reactivation_count}"
    )

    payload = {
      event: 'proactive_reengagement',
      idempotency_key: idempotency_key,
      attempt: @reengagement.current_attempt + 1,
      max_attempts: attempts.length,
      trigger_started_at: @reengagement.trigger_started_at&.iso8601,
      conversation: @conversation.webhook_data,
      account: { id: @conversation.account_id, name: @conversation.account.name },
      agent_bot_id: @agent_bot.id,
      agent_bot_config: {
        assistant_config: @agent_bot.assistant_config,
        agent_behavior_config: @agent_bot.agent_behavior_config,
        has_openai_api_key: @agent_bot.has_openai_api_key?,
        has_google_api_key: @agent_bot.has_google_api_key?,
        has_pinecone_api_key: @agent_bot.account&.pinecone_api_key.present?
      }
    }

    AgentBots::WebhookJob.perform_later(
      @agent_bot.outgoing_url,
      payload,
      :proactive_reengagement,
      idempotency_key
    )
  end
end
