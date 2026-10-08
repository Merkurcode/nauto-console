# POST síncrono al outgoing_url de un Agent Bot (p. ej. lead_followup.first_contact_request),
# con agent_bot_id en el payload y firma HMAC, igual que los webhooks de AgentBots::WebhookJob.
class AgentBots::DirectWebhook
  def self.post(agent_bot, payload, timeout: 30)
    body = payload.merge(agent_bot_id: agent_bot.id).to_json
    headers = { 'Content-Type' => 'application/json' }.merge(AgentBots::WebhookSigner.headers(agent_bot, body))
    HTTParty.post(agent_bot.outgoing_url, body: body, headers: headers, timeout: timeout)
  end
end
