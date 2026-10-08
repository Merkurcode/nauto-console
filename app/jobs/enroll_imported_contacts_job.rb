# rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/ParameterLists
class EnrollImportedContactsJob < ApplicationJob
  queue_as :default

  BATCH_SIZE = 1000

  def perform(sequence_id, last_id = 0)
    sequence = LeadFollowUpSequence.find_by(id: sequence_id)
    return unless sequence&.active? && sequence.source_type == 'imported_contacts'

    first_step = sequence.enabled_steps.first
    unless first_step
      Rails.logger.warn "Sequence #{sequence.id} has no enabled steps, skipping enrollment"
      return
    end

    contacts = build_contacts_query(sequence)
               .where('contacts.id > ?', last_id)
               .order('contacts.id ASC')
               .limit(BATCH_SIZE)
    total_in_batch = contacts.length

    enrolled_count = 0
    skipped_count = 0

    contacts.each do |contact|
      conversation = create_conversation_with_first_contact(sequence, contact)
      unless conversation
        skipped_count += 1
        next
      end

      enroll_conversation(conversation, sequence, first_step, contact)
      enrolled_count += 1
    rescue StandardError => e
      Rails.logger.error "Failed to enroll contact #{contact.id} in sequence #{sequence_id}: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n") if e.backtrace
      skipped_count += 1
    end

    Rails.logger.info "EnrollImportedContacts sequence=#{sequence_id} last_id=#{last_id} enrolled=#{enrolled_count} skipped=#{skipped_count}"

    self.class.perform_later(sequence_id, contacts.last.id) if total_in_batch == BATCH_SIZE
  end

  private

  def build_contacts_query(sequence)
    config = sequence.source_config || {}
    scope = sequence.account.contacts

    if config['labels'].present?
      match_any = config['label_match'] != 'all'
      scope = scope.tagged_with(config['labels'], any: match_any)
    end

    scope = scope.where(contact_type: config['contact_types']) if config['contact_types'].present?
    scope = scope.where.not(phone_number: [nil, '']) if config['require_phone']
    scope = scope.where.not(email: [nil, '']) if config['require_email']
    scope = apply_created_at_filter(scope, config['created_at_filter'])
    scope = apply_additional_attribute_filters(scope, config['additional_attribute_filters'])
    apply_custom_attribute_filters(scope, config['custom_attribute_filters'])
  end

  def apply_created_at_filter(scope, filter)
    return scope unless filter&.dig('enabled')

    case filter['operator']
    when 'newer_than'
      scope.where('contacts.created_at >= ?', filter['value'].to_i.days.ago)
    when 'older_than'
      scope.where('contacts.created_at <= ?', filter['value'].to_i.days.ago)
    when 'between'
      from = Date.parse(filter['from_date'])
      to   = Date.parse(filter['to_date'])
      scope.where(created_at: from.beginning_of_day..to.end_of_day)
    else
      scope
    end
  rescue StandardError => e
    Rails.logger.error "Error applying created_at filter: #{e.message}"
    scope
  end

  def apply_additional_attribute_filters(scope, filters)
    return scope if filters.blank?

    filters.each do |f|
      key = f['attribute_key']
      val = f['value']
      scope = case f['operator']
              when 'equals'
                scope.where('contacts.additional_attributes->>? = ?', key, val.to_s)
              when 'not_equals'
                scope.where('contacts.additional_attributes->>? != ?', key, val.to_s)
              when 'contains'
                scope.where('contacts.additional_attributes->>? ILIKE ?', key, "%#{val}%")
              when 'is_present'
                scope.where(
                  "contacts.additional_attributes->>? IS NOT NULL AND contacts.additional_attributes->>? != ''",
                  key, key
                )
              when 'is_not_present'
                scope.where(
                  "contacts.additional_attributes->>? IS NULL OR contacts.additional_attributes->>? = ''",
                  key, key
                )
              else
                scope
              end
    end

    scope
  end

  def apply_custom_attribute_filters(scope, filters)
    return scope if filters.blank?

    # Group consecutive AND filters; each OR boundary starts a new group.
    # [F1, F2(AND), F3(OR), F4(AND)] → [[F1,F2], [F3,F4]] → (F1∧F2) ∨ (F3∧F4)
    groups = filters.each_with_object([[]]) do |f, acc|
      acc << [] if f['logical_operator'] == 'or' && acc.last.any?
      acc.last << f
    end

    or_parts = []
    binds = []
    groups.each do |group|
      and_parts = []
      group.each do |f|
        sql, b = custom_attr_filter_sql(f)
        next unless sql

        and_parts << sql
        binds.concat(b)
      end
      or_parts << "(#{and_parts.join(' AND ')})" if and_parts.any?
    end

    return scope if or_parts.empty?

    scope.where(or_parts.join(' OR '), *binds)
  end

  def custom_attr_filter_sql(filter)
    key = filter['attribute_key']
    val = filter['value']
    col = 'contacts.custom_attributes'

    case filter['operator']
    when 'equal_to'
      # @> uses the existing GIN index on custom_attributes
      ["#{col} @> jsonb_build_object(?, ?::text)", [key, val.to_s]]
    when 'not_equal_to'
      ["(#{col}->>? IS NOT NULL AND #{col}->>? != ?)", [key, key, val.to_s]]
    when 'contains'
      ["#{col}->>? ILIKE ?", [key, "%#{ActiveRecord::Base.sanitize_sql_like(val.to_s)}%"]]
    when 'is_present'
      ["(#{col}->>? IS NOT NULL AND #{col}->>? != '')", [key, key]]
    when 'is_not_present'
      ["(#{col}->>? IS NULL OR #{col}->>? = '')", [key, key]]
    end
  end

  def create_conversation_with_first_contact(sequence, contact)
    inbox = get_inbox_for_sequence(sequence)
    return nil unless inbox

    contact_inbox = contact.contact_inboxes.find_by(inbox: inbox)
    unless contact_inbox
      source_id = generate_source_id_for_inbox(contact.phone_number, inbox, email: contact.email)
      contact_inbox = ContactInbox.create!(contact: contact, inbox: inbox, source_id: source_id)
    end

    existing_conversation = contact_inbox.conversations.last

    if existing_conversation && !existing_conversation.resolved?
      follow_up = existing_conversation.conversation_follow_up
      include_completed = sequence.trigger_conditions.dig('enrollment_filter', 'include_completed')

      should_send = if follow_up&.status == 'active'
                      false
                    elsif follow_up&.status == 'completed'
                      include_completed
                    else
                      true
                    end

      send_first_contact_message(sequence, existing_conversation, contact) if should_send
      return existing_conversation
    end

    conversation = ConversationBuilder.new(
      params: {
        contact_id: contact.id,
        inbox_id: inbox.id,
        source_type: :api,
        source_metadata: {
          imported_contacts_sequence_id: sequence.id,
          contact_id: contact.id,
          created_at: Time.current.iso8601
        }
      },
      contact_inbox: contact_inbox
    ).perform

    send_first_contact_message(sequence, conversation, contact)
    conversation
  rescue StandardError => e
    Rails.logger.error "Failed to create conversation for contact #{contact.id}: #{e.message}"
    nil
  end

  def send_first_contact_message(sequence, conversation, contact)
    first_step = sequence.steps.find { |s| s['type'] == 'first_contact' }
    return unless first_step

    config = first_step['config']

    case config['channel']
    when 'whatsapp'
      send_whatsapp_template(sequence, conversation, contact, config)
    when 'sms'
      send_ai_sms_first_contact(sequence, conversation, contact, config)
    when 'email'
      send_email_first_contact(sequence, conversation, contact, config)
    else
      Rails.logger.error "Unknown first contact channel: #{config['channel']}"
    end
  end

  def send_whatsapp_template(sequence, conversation, contact, config)
    idempotency_key = "first_contact-#{sequence.id}-contact_#{contact.id}-imported"
    if conversation.messages.where(message_type: :template)
                   .exists?(["content_attributes->>'idempotency_key' = ?", idempotency_key])
      Rails.logger.info "Template already sent for contact #{contact.id} in sequence #{sequence.id}, skipping"
      return
    end

    template_name = config['template_name']
    template_params = config['template_params'] || {}
    rendered_params = render_template_params(template_params, contact)

    channel = conversation.inbox.channel
    processor = Whatsapp::TemplateProcessorService.new(
      channel: channel,
      template_params: {
        'name' => template_name,
        'language' => config['language'] || 'es',
        'processed_params' => rendered_params
      }
    )

    name, namespace, lang_code, _processed_parameters = processor.call
    raise "Template '#{template_name}' not found" if name.blank?

    rendered_content = render_template_content(conversation, name, lang_code, rendered_params)

    conversation.messages.create!(
      :account_id => sequence.account.id,
      :inbox_id => conversation.inbox.id,
      :message_type => :template,
      :content => rendered_content,
      :status => :sent,
      :content_attributes => {
        template_name: name,
        contact_id: contact.id,
        idempotency_key: idempotency_key
      },
      'additional_attributes' => {
        'template_params' => {
          'name' => name.to_s,
          'namespace' => namespace.to_s,
          'language' => lang_code.to_s,
          'processed_params' => rendered_params
        }
      }
    )
  rescue StandardError => e
    Rails.logger.error "Failed to send WhatsApp template to contact #{contact.id}: #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n") if e.backtrace
    conversation.messages.create!(
      account_id: sequence.account.id,
      inbox_id: conversation.inbox.id,
      message_type: :activity,
      content: "Failed to send WhatsApp template: #{e.message}",
      content_attributes: { error: e.message, contact_id: contact.id, failed_at: Time.current.iso8601 }
    )
  end

  def send_ai_sms_first_contact(sequence, conversation, contact, config)
    agent_bot = conversation.inbox.agent_bot
    raise "No agent bot configured for inbox #{conversation.inbox.id}" unless agent_bot

    step = sequence.steps.find { |s| s['type'] == 'first_contact' }
    rendered_context = render_param_value(config['sms_context'] || '', contact)

    payload = build_first_contact_payload(
      sequence: sequence, conversation: conversation, contact: contact,
      step: step, channel: 'sms', reply_inbox: conversation.inbox,
      context: rendered_context, variables: {}
    )

    post_first_contact_webhook(agent_bot, payload, 'sms', conversation.id)
  rescue StandardError => e
    Rails.logger.error "Failed to send SMS first contact to contact #{contact.id}: #{e.message}"
    raise
  end

  def send_email_first_contact(sequence, conversation, contact, config)
    inbox = sequence.account.inboxes.find_by(id: config['inbox_id'])
    raise "Email inbox #{config['inbox_id']} not found" unless inbox

    agent_bot = inbox.agent_bot
    raise "No agent bot configured for email inbox #{inbox.id}" unless agent_bot

    step = sequence.steps.find { |s| s['type'] == 'first_contact' }
    rendered_context = render_param_value(config['email_context'] || '', contact)
    rendered_subject = render_param_value(config['subject'] || '', contact)
    rendered_content = render_param_value(config['content'] || '', contact)
    sender_email = config['sender_email'].presence || sequence.account.support_email

    payload = build_first_contact_payload(
      sequence: sequence, conversation: conversation, contact: contact,
      step: step, channel: 'email', reply_inbox: inbox,
      context: rendered_context,
      variables: {
        to_email: contact.email,
        sender_email: sender_email,
        subject: rendered_subject,
        content: rendered_content
      }
    )

    post_first_contact_webhook(agent_bot, payload, 'email', conversation.id)
  rescue StandardError => e
    Rails.logger.error "Failed to send email first contact to contact #{contact.id}: #{e.message}"
    raise
  end

  def enroll_conversation(conversation, sequence, _first_step, contact)
    if conversation.sequence_enrollments.exists?(lead_follow_up_sequence: sequence, status: 'active')
      Rails.logger.info "Conversation #{conversation.id} already has active enrollment, skipping"
      return
    end

    active_follow_up = conversation.conversation_follow_up
    if active_follow_up&.status == 'active'
      Rails.logger.info "Conversation #{conversation.id} already has active follow-up, skipping"
      return
    end

    existing_enrollment = conversation.sequence_enrollments
                                      .where(lead_follow_up_sequence: sequence)
                                      .order(enrolled_at: :desc).first

    if existing_enrollment&.status == 'completed'
      include_completed = sequence.trigger_conditions.dig('enrollment_filter', 'include_completed')
      unless include_completed
        Rails.logger.info "Skipping re-enrollment for conversation #{conversation.id}: include_completed is false"
        return
      end
    end

    re_enrollment_count = conversation.sequence_enrollments
                                      .where(lead_follow_up_sequence: sequence).count

    enabled_steps = sequence.enabled_steps

    enrollment = SequenceEnrollment.create!(
      conversation: conversation,
      lead_follow_up_sequence: sequence,
      enrolled_at: Time.current,
      status: 'active',
      current_step: 1,
      metadata: {
        enrolled_via: 'imported_contacts',
        contact_id: contact.id,
        re_enrollment_count: re_enrollment_count
      }
    )

    enrollment.create_event(
      event_type: 'enrolled',
      step_id: nil,
      step_index: nil,
      metadata: { source: 'imported_contacts', contact_id: contact.id, re_enrollment: re_enrollment_count.positive? }
    )

    first_contact_step = enabled_steps.first
    enrollment.create_event(
      event_type: 'step_executed',
      step_id: first_contact_step['id'],
      step_index: 0,
      metadata: { step_type: 'first_contact', channel: first_contact_step.dig('config', 'channel'), auto_executed: true }
    )

    if enabled_steps.length == 1
      enrollment.complete!('All steps completed after first_contact')
      sequence.update_stats!
    else
      next_step = enabled_steps[1]
      next_action_at = calculate_wait_time_from_now(next_step)

      follow_up = ConversationFollowUp.find_or_initialize_by(conversation: conversation)
      follow_up.assign_attributes(
        lead_follow_up_sequence: sequence,
        sequence_enrollment: enrollment,
        current_step: 1,
        next_action_at: next_action_at,
        status: 'active',
        completed_at: nil,
        processing_started_at: nil,
        metadata: (follow_up.metadata || {}).merge({ enrolled_at: Time.current, enrollment_id: enrollment.id })
      )
      follow_up.save!
      follow_up.schedule_job!
    end
  end

  def calculate_wait_time_from_now(step)
    return Time.current unless step['type'] == 'wait'

    config = step['config']
    delay = config['delay_value'].to_i
    calculated = case config['delay_type']
                 when 'minutes' then Time.current + delay.minutes
                 when 'hours'   then Time.current + delay.hours
                 when 'days'    then Time.current + delay.days
                 else Time.current + delay.hours # rubocop:disable Lint/DuplicateBranch
                 end
    [calculated, Time.current].max
  end

  def get_inbox_for_sequence(sequence)
    first_step = sequence.steps.find { |s| s['type'] == 'first_contact' }
    return nil unless first_step

    inbox_id = first_step.dig('config', 'inbox_id')
    sequence.account.inboxes.find_by(id: inbox_id)
  end

  def generate_source_id_for_inbox(phone_number, inbox, email: nil)
    if inbox.channel_type == 'Channel::Whatsapp'
      phone_number&.delete('+') || email
    elsif inbox.channel_type == 'Channel::Email'
      email || phone_number
    else
      phone_number || email
    end
  end

  def render_template_params(template_params, contact)
    return template_params unless template_params.is_a?(Hash)

    rendered = {}
    template_params.each do |key, value|
      rendered[key] = if value.is_a?(Hash)
                        render_template_params(value, contact)
                      elsif value.is_a?(String)
                        render_param_value(value, contact)
                      else
                        value
                      end
    end
    rendered
  end

  def render_param_value(value, contact)
    return value unless value.is_a?(String)

    result = value.dup
    result.gsub!('{{contact.name}}', contact.name.to_s)
    result.gsub!('{{contact.phone_number}}', contact.phone_number.to_s)
    result.gsub!('{{contact.email}}', contact.email.to_s)
    result.gsub!('{{contact.city}}', contact.additional_attributes&.dig('city').to_s)

    result.scan(/\{\{custom_attr\.([^}]+)\}\}/).each do |match|
      attr_key = match[0]
      attr_value = contact.custom_attributes&.dig(attr_key)
      result.gsub!("{{custom_attr.#{attr_key}}}", attr_value.to_s)
    end

    result
  end

  def render_template_content(conversation, template_name, language, params)
    template = find_template(conversation.inbox.channel, template_name, language)
    return "Template: #{template_name}" if template.blank?

    body_component = template['components']&.find { |c| c['type'] == 'BODY' }
    return "Template: #{template_name}" if body_component.blank?

    template_text = body_component['text']
    return template_text if template_text.blank? || params.blank?

    rendered_text = template_text.dup
    body_params = params['body'] || {}
    body_params.each do |key, value|
      rendered_text.gsub!("{{#{key}}}", value.to_s)
    end
    rendered_text
  end

  def find_template(channel, template_name, language)
    @template_cache ||= {}
    cache_key = "#{channel.id}:#{template_name}:#{language}"
    return @template_cache[cache_key] if @template_cache.key?(cache_key)

    @template_cache[cache_key] = channel.message_templates&.find { |t| t['name'] == template_name && t['language'] == language }
  end

  def build_first_contact_payload(sequence:, conversation:, contact:, step:, channel:, reply_inbox:, context:, variables:)
    last_message = conversation.messages.where.not(message_type: :activity).order(created_at: :desc).first

    {
      event: 'lead_followup.first_contact_request',
      idempotency_key: "first_contact-#{sequence.id}-contact_#{contact.id}-#{step&.dig('id')}",
      account: sequence.account.webhook_data,
      inbox: conversation.inbox.webhook_data,
      conversation: conversation.webhook_data.merge(
        last_activity_at: conversation.last_activity_at.to_i,
        last_message_at: last_message&.created_at&.to_i
      ),
      contact: contact.push_event_data,
      follow_up_data: {
        sequence_id: sequence.id,
        sequence_name: sequence.name,
        step_id: step&.dig('id'),
        step_name: step&.dig('name'),
        current_step: 0,
        message_channel: channel,
        reply_inbox: {
          id: reply_inbox.id,
          name: reply_inbox.name,
          channel_type: reply_inbox.channel_type,
          phone_number: reply_inbox.channel&.try(:phone_number),
          email: reply_inbox.channel&.try(:email)
        },
        context: context,
        variables: variables,
        contact_data: {
          contact_id: contact.id,
          labels: contact.label_list
        }
      }
    }
  end

  def post_first_contact_webhook(agent_bot, payload, channel, conversation_id)
    AgentBots::DirectWebhook.post(agent_bot, payload)
    Rails.logger.info "Sent #{channel} first contact request for conversation #{conversation_id}"
  end
end
# rubocop:enable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/ParameterLists
