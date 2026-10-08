class FollowUpResultAnalysisJob < ApplicationJob
  queue_as :default

  def perform(enrollment_id)
    enrollment = SequenceEnrollment.find_by(id: enrollment_id)
    return unless enrollment

    sequence = enrollment.lead_follow_up_sequence
    return if sequence.result_schema.blank?

    conversation = enrollment.conversation
    agent_bot = conversation.inbox.agent_bot
    return if agent_bot&.outgoing_url.blank?

    payload = build_payload(enrollment, sequence, conversation, agent_bot)
    idempotency_key = Digest::SHA256.hexdigest("result-analysis-#{enrollment.id}")

    AgentBots::WebhookJob.perform_later(
      agent_bot.outgoing_url,
      payload,
      :lead_followup_result_analysis,
      idempotency_key
    )
  end

  private

  def build_payload(enrollment, sequence, conversation, agent_bot)
    {
      event: 'lead_followup.result_analysis_request',
      account: conversation.account.webhook_data,
      inbox: conversation.inbox.webhook_data,
      conversation: conversation.webhook_data,
      contact: conversation.contact.push_event_data,
      enrollment: {
        id: enrollment.id,
        status: enrollment.status,
        completion_reason: enrollment.completion_reason,
        enrolled_at: enrollment.enrolled_at&.iso8601,
        completed_at: enrollment.completed_at&.iso8601
      },
      result_schema: sequence.result_schema,
      agent_bot_id: agent_bot.id,
      agent_bot_config: {
        assistant_config: agent_bot.assistant_config,
        agent_behavior_config: agent_bot.agent_behavior_config,
        has_openai_api_key: agent_bot.has_openai_api_key?,
        has_google_api_key: agent_bot.has_google_api_key?
      }
    }
  end
end
