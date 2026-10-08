require 'rails_helper'

RSpec.describe AgentBots::DirectWebhook do
  let(:agent_bot) { create(:agent_bot, secret: 'bot-secret', outgoing_url: 'https://agents.example.com/webhook') }
  let(:payload) { { event: 'lead_followup.first_contact_request', idempotency_key: 'k1' } }

  it 'posts the payload with agent_bot_id and a valid signature' do
    captured = nil
    allow(HTTParty).to receive(:post) { |url, opts| captured = [url, opts] }

    described_class.post(agent_bot, payload)

    url, opts = captured
    expect(url).to eq('https://agents.example.com/webhook')
    expect(JSON.parse(opts[:body])).to include('event' => 'lead_followup.first_contact_request', 'agent_bot_id' => agent_bot.id)
    expect(opts[:timeout]).to eq(30)

    timestamp = opts[:headers]['X-Nauto-Timestamp']
    expected = OpenSSL::HMAC.hexdigest('SHA256', 'bot-secret', "#{timestamp}.#{opts[:body]}")
    expect(opts[:headers]['X-Nauto-Signature']).to eq("sha256=#{expected}")
    expect(opts[:headers]['Content-Type']).to eq('application/json')
  end
end
