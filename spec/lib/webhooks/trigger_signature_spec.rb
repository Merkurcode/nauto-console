require 'rails_helper'

describe Webhooks::Trigger do
  let(:url) { 'https://agents.test/webhook' }
  let(:agent_bot) { create(:agent_bot, secret: 'bot-secret') }

  before do
    allow(GlobalConfig).to receive(:get_value).and_call_original
    allow(GlobalConfig).to receive(:get_value).with('WEBHOOK_TIMEOUT').and_return(5)
  end

  it 'adds the HMAC headers when the payload targets an agent bot' do
    payload = { event: 'message_created', agent_bot_id: agent_bot.id, idempotency_key: 'k1' }

    expect(RestClient::Request).to receive(:execute) do |args|
      timestamp = args[:headers]['X-Nauto-Timestamp']
      expected = OpenSSL::HMAC.hexdigest('SHA256', 'bot-secret', "#{timestamp}.#{args[:payload]}")
      expect(args[:payload]).to eq(payload.to_json)
      expect(args[:headers]['X-Nauto-Signature']).to eq("sha256=#{expected}")
    end

    described_class.execute(url, payload, :agent_bot_webhook)
  end

  it 'does not sign payloads without agent_bot_id' do
    expect(RestClient::Request).to receive(:execute) do |args|
      expect(args[:headers]).not_to include('X-Nauto-Signature')
    end

    described_class.execute(url, { event: 'faq_catalog_updated' }, :account_webhook)
  end
end
