require 'rails_helper'

RSpec.describe Accounts::SetupNautoWebhooksService do
  let!(:account) { create(:account) }

  def setup
    described_class.new(account).perform
  end

  it 'keeps nauto-assistant by default (bot + sync webhooks)' do
    with_modified_env NAUTO_ASSISTANT_URL: 'https://assistant.example.com', NAUTO_AGENTS_URL: 'https://agents.example.com' do
      expect { setup }.to change(AgentBot, :count).by(1).and change(account.webhooks, :count).by(3)
    end
    expect(AgentBot.last.outgoing_url).to eq('https://assistant.example.com/unified_webhook')
  end

  it 'points the bot of new accounts to nauto-agents when enabled, without sync webhooks' do
    with_modified_env NEW_ACCOUNTS_AI_BACKEND: 'nauto_agents', NAUTO_AGENTS_URL: 'https://agents.example.com/',
                      NAUTO_ASSISTANT_URL: 'https://assistant.example.com' do
      expect { setup }.to change(AgentBot, :count).by(1).and(not_change(account.webhooks, :count))
    end
    expect(AgentBot.last).to have_attributes(account_id: account.id, outgoing_url: 'https://agents.example.com/webhook')
  end

  it 'falls back to nauto-assistant when nauto_agents is selected but NAUTO_AGENTS_URL is missing' do
    with_modified_env NEW_ACCOUNTS_AI_BACKEND: 'nauto_agents', NAUTO_AGENTS_URL: '', NAUTO_ASSISTANT_URL: 'https://assistant.example.com' do
      setup
    end
    expect(AgentBot.last.outgoing_url).to eq('https://assistant.example.com/unified_webhook')
  end
end
