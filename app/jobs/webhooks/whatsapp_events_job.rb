class Webhooks::WhatsappEventsJob < MutexApplicationJob
  queue_as :low
  retry_on LockAcquisitionError, wait: 1.second, attempts: 8

  def perform(params = {})
    waba_id = partner_removed_waba_id(params)
    return prompt_reauthorization_for(waba_id) if waba_id

    channel = find_channel_from_whatsapp_business_payload(params)

    if channel_is_inactive?(channel)
      Rails.logger.warn("Inactive WhatsApp channel: #{channel&.phone_number || "unknown - #{params[:phone_number]}"}")
      return
    end

    sender_id = message_sender_id(params)
    return process_events(channel, params) if sender_id.blank?

    # Messages from the same sender are processed one at a time to prevent creating double conversations
    key = format(::Redis::Alfred::WHATSAPP_MESSAGE_MUTEX, inbox_id: channel.inbox.id, sender_id: sender_id)
    with_lock(key) { process_events(channel, params) }
  end

  private

  def process_events(channel, params)
    case channel.provider
    when 'whatsapp_cloud'
      Whatsapp::IncomingMessageWhatsappCloudService.new(inbox: channel.inbox, params: params).perform
    else
      Whatsapp::IncomingMessageService.new(inbox: channel.inbox, params: params).perform
    end

    # Track Meta campaign interactions if referral data is present
    track_meta_campaign_interaction(params, channel.inbox) if has_referral_data?(params)
  end

  # Status updates carry no sender and don't create conversations, so they skip the lock
  def message_sender_id(params)
    value = params[:entry]&.first&.dig(:changes, 0, :value) || params
    value.dig(:messages, 0, :from) || value.dig(:message_echoes, 0, :to)
  end

  # Coexistence: the business disconnected the number from the WhatsApp Business app (or Meta did it for inactivity)
  def partner_removed_waba_id(params)
    change = params[:entry]&.first&.dig(:changes, 0) || {}
    return unless change[:field] == 'account_update' && change.dig(:value, :event) == 'PARTNER_REMOVED'

    change.dig(:value, :waba_info, :waba_id)
  end

  def prompt_reauthorization_for(waba_id)
    Channel::Whatsapp.where("provider_config->>'business_account_id' = ?", waba_id).find_each(&:prompt_reauthorization!)
  end

  def channel_is_inactive?(channel)
    return true if channel.blank?
    return true if channel.reauthorization_required?
    return true unless channel.account.active?

    false
  end

  def find_channel_by_url_param(params)
    return unless params[:phone_number]

    Channel::Whatsapp.find_by(phone_number: params[:phone_number])
  end

  def find_channel_from_whatsapp_business_payload(params)
    # for the case where facebook cloud api support multiple numbers for a single app
    # https://github.com/chatwoot/chatwoot/issues/4712#issuecomment-1173838350
    # we will give priority to the phone_number in the payload
    return get_channel_from_wb_payload(params) if params[:object] == 'whatsapp_business_account'

    find_channel_by_url_param(params)
  end

  def get_channel_from_wb_payload(wb_params)
    phone_number = "+#{wb_params[:entry].first[:changes].first.dig(:value, :metadata, :display_phone_number)}"
    phone_number_id = wb_params[:entry].first[:changes].first.dig(:value, :metadata, :phone_number_id)
    channel = Channel::Whatsapp.find_by(phone_number: phone_number)
    # validate to ensure the phone number id matches the whatsapp channel
    return channel if channel && channel.provider_config['phone_number_id'] == phone_number_id
  end

  def has_referral_data?(params)
    return false unless params[:entry].present?

    first_message = params[:entry].first&.dig(:changes, 0, :value, :messages, 0)
    first_message&.dig(:referral).present?
  end

  def track_meta_campaign_interaction(params, inbox)
    first_message = params[:entry].first&.dig(:changes, 0, :value, :messages, 0)
    referral = first_message&.dig(:referral)
    return unless referral.present?

    # Find the message by source_id
    message = Message.find_by(source_id: first_message[:id], inbox_id: inbox.id)
    return unless message

    # Track the interaction
    MetaCampaigns::InteractionTrackerService.new(message: message).perform
  rescue StandardError => e
    Rails.logger.error "Error tracking Meta campaign interaction: #{e.message}"
  end
end
