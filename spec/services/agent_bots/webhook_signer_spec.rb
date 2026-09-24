require 'rails_helper'

RSpec.describe AgentBots::WebhookSigner do
  let(:agent_bot) { create(:agent_bot, secret: 'bot-secret') }
  let(:body) { { event: 'message_created', agent_bot_id: agent_bot.id }.to_json }

  it 'signs timestamp and raw body with the bot secret' do
    headers = described_class.headers(agent_bot, body, timestamp: 1_700_000_000)

    expected = OpenSSL::HMAC.hexdigest('SHA256', 'bot-secret', "1700000000.#{body}")
    expect(headers).to eq('X-Nauto-Timestamp' => '1700000000', 'X-Nauto-Signature' => "sha256=#{expected}")
  end

  it 'generates and persists a secret when the bot has none' do
    bot = create(:agent_bot, secret: nil)

    described_class.headers(bot, body)

    expect(bot.reload.secret).to be_present
  end
end
