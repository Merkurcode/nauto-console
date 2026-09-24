# Firma HMAC de los webhooks que se envían al outgoing_url de un Agent Bot.
#
#   X-Nauto-Timestamp: <unix seconds>
#   X-Nauto-Signature: sha256=<hex HMAC-SHA256(agent_bot.secret, "#{timestamp}.#{raw_body}")>
#
# raw_body debe ser exactamente el string enviado como body.
class AgentBots::WebhookSigner
  TIMESTAMP_HEADER = 'X-Nauto-Timestamp'.freeze
  SIGNATURE_HEADER = 'X-Nauto-Signature'.freeze

  def self.headers(agent_bot, raw_body, timestamp: Time.now.to_i)
    signature = OpenSSL::HMAC.hexdigest('SHA256', agent_bot.ensure_secret!, "#{timestamp}.#{raw_body}")
    { TIMESTAMP_HEADER => timestamp.to_s, SIGNATURE_HEADER => "sha256=#{signature}" }
  end
end
