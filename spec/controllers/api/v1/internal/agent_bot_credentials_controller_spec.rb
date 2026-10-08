require 'rails_helper'

RSpec.describe 'Internal Agent Bot Credentials API', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:agent_bot) { create(:agent_bot, account: account, openai_api_key: 'sk-test') }
  let(:path) { "/api/v1/internal/agent_bots/#{agent_bot.id}/credentials" }
  let(:auth) { { 'Authorization' => 'Bearer service-token' } }

  before { create(:agent_bot_inbox, agent_bot: agent_bot, inbox: inbox) }

  it 'returns unauthorized when the service token is not configured' do
    with_modified_env NAUTO_AGENTS_SERVICE_TOKEN: nil do
      get path, headers: auth
    end

    expect(response).to have_http_status(:unauthorized)
  end

  it 'returns unauthorized with a wrong token' do
    with_modified_env NAUTO_AGENTS_SERVICE_TOKEN: 'service-token' do
      get path, headers: { 'Authorization' => 'Bearer wrong' }
    end

    expect(response).to have_http_status(:unauthorized)
  end

  it 'returns not found for an unknown bot' do
    with_modified_env NAUTO_AGENTS_SERVICE_TOKEN: 'service-token' do
      get '/api/v1/internal/agent_bots/0/credentials', headers: auth
    end

    expect(response).to have_http_status(:not_found)
  end

  it 'returns the bot credentials' do
    with_modified_env NAUTO_AGENTS_SERVICE_TOKEN: 'service-token' do
      get path, headers: auth
    end

    expect(response).to have_http_status(:success)
    body = response.parsed_body
    expect(body).to include(
      'agent_bot_id' => agent_bot.id,
      'account_id' => account.id,
      'access_token' => agent_bot.access_token.token,
      'inbox_ids' => [inbox.id],
      'openai_api_key' => 'sk-test',
      'google_api_key' => nil
    )
    expect(body['secret']).to be_present
    expect(agent_bot.reload.secret).to eq(body['secret'])
  end
end
