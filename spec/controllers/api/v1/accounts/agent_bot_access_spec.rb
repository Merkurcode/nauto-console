require 'rails_helper'

# Endpoints que nauto-agents consume con el token del Agent Bot.
RSpec.describe 'Agent bot token access', type: :request do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:agent_bot) { create(:agent_bot, account: account) }
  let(:headers) { { api_access_token: agent_bot.access_token.token } }

  before { create(:agent_bot_inbox, agent_bot: agent_bot, inbox: inbox) }

  {
    'faq items' => ->(a, _i) { "/api/v1/accounts/#{a.id}/faq_items" },
    'product catalogs' => ->(a, _i) { "/api/v1/accounts/#{a.id}/product_catalogs" },
    'marketing campaigns' => ->(a, _i) { "/api/v1/accounts/#{a.id}/marketing_campaigns" },
    'inbox members' => ->(a, i) { "/api/v1/accounts/#{a.id}/inbox_members/#{i.id}" },
    'account profile' => ->(a, _i) { "/api/v1/accounts/#{a.id}" }
  }.each do |name, path|
    it "allows the bot to read #{name} of its account" do
      get path.call(account, inbox), headers: headers, as: :json

      expect(response).to have_http_status(:success)
    end
  end

  it 'allows the bot to read and update a contact of its account' do
    contact = create(:contact, account: account)

    get "/api/v1/accounts/#{account.id}/contacts/#{contact.id}", headers: headers, as: :json
    expect(response).to have_http_status(:success)

    patch "/api/v1/accounts/#{account.id}/contacts/#{contact.id}", headers: headers, params: { name: 'Nuevo' }, as: :json
    expect(response).to have_http_status(:success)
    expect(contact.reload.name).to eq('Nuevo')
  end

  it 'rejects access to another account' do
    get "/api/v1/accounts/#{other_account.id}/faq_items", headers: headers, as: :json
    expect(response).to have_http_status(:unauthorized)

    get "/api/v1/accounts/#{other_account.id}", headers: headers, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'keeps write endpoints closed for bots' do
    post "/api/v1/accounts/#{account.id}/faq_items", headers: headers, params: {}, as: :json

    expect(response).to have_http_status(:unauthorized)
  end
end
