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
    'account profile' => ->(a, _i) { "/api/v1/accounts/#{a.id}" },
    'labels' => ->(a, _i) { "/api/v1/accounts/#{a.id}/labels" },
    'custom attribute definitions' => ->(a, _i) { "/api/v1/accounts/#{a.id}/custom_attribute_definitions?attribute_model=contact_attribute" }
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

  it 'allows the bot to read and set labels of a conversation and a contact of its account' do
    create(:label, account: account, title: 'interesado')
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, inbox: inbox, contact: contact)

    post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/labels",
         params: { labels: ['interesado'] }, headers: headers, as: :json
    expect(response).to have_http_status(:success)
    get "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/labels", headers: headers, as: :json
    expect(response.parsed_body['payload']).to eq(['interesado'])

    post "/api/v1/accounts/#{account.id}/contacts/#{contact.id}/labels",
         params: { labels: ['interesado'] }, headers: headers, as: :json
    expect(response).to have_http_status(:success)
    expect(contact.reload.label_list).to eq(['interesado'])
  end

  it 'does not let the bot create labels or definitions' do
    post "/api/v1/accounts/#{account.id}/labels", params: { title: 'nueva' }, headers: headers, as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  describe 'appointments (nauto-agents citas)' do
    let(:owner) { create(:user, account: account, role: :agent) }
    # Horario por defecto del asesor: lunes a viernes, 9 a 17 (UTC si no tiene zona horaria).
    let(:next_monday_at_ten) { Time.zone.now.next_occurring(:monday).change(hour: 10) }
    let(:contact) { create(:contact, account: account) }
    let(:params) do
      {
        contact_id: contact.id,
        appointment: {
          scheduled_at: next_monday_at_ten.iso8601, appointment_type: 'physical_visit',
          owner_id: owner.id, location: 'Clínica San Nicolás', description: 'Check Up Dental', inbox_id: inbox.id
        }
      }
    end

    it 'lets the bot create, list and cancel an appointment of its account' do
      post "/api/v1/accounts/#{account.id}/appointments", params: params, headers: headers, as: :json
      expect(response).to have_http_status(:created)
      appointment_id = response.parsed_body['id']
      expect(Appointment.find(appointment_id).owner_id).to eq(owner.id)

      get "/api/v1/accounts/#{account.id}/appointments", headers: headers, as: :json
      expect(response).to have_http_status(:success)
      expect(response.parsed_body['payload'].map { |a| a['id'] }).to include(appointment_id)

      post "/api/v1/accounts/#{account.id}/appointments/#{appointment_id}/cancel", headers: headers, as: :json
      expect(response).to have_http_status(:success)
      expect(Appointment.find(appointment_id)).to be_cancelled
    end

    it 'does not apply the advisor overlap or working hours to bot appointments' do
      post "/api/v1/accounts/#{account.id}/appointments", params: params, headers: headers, as: :json
      post "/api/v1/accounts/#{account.id}/appointments", params: params, headers: headers, as: :json
      expect(response).to have_http_status(:created)

      sunday = Time.zone.now.next_occurring(:sunday).change(hour: 16)
      post "/api/v1/accounts/#{account.id}/appointments", headers: headers, as: :json,
                                                          params: params.deep_merge(appointment: { scheduled_at: sunday.iso8601 })
      expect(response).to have_http_status(:created)

      # Cancelar una cita fuera del horario del asesor también pasa (antes el cambio de estado revalidaba el horario).
      post "/api/v1/accounts/#{account.id}/appointments/#{response.parsed_body['id']}/cancel", headers: headers, as: :json
      expect(response).to have_http_status(:success)
    end

    it 'still validates the advisor schedule for appointments created by users' do
      admin = create(:user, account: account, role: :administrator)
      sunday = Time.zone.now.next_occurring(:sunday).change(hour: 16)
      post "/api/v1/accounts/#{account.id}/appointments", headers: { api_access_token: admin.access_token.token }, as: :json,
                                                          params: params.deep_merge(appointment: { scheduled_at: sunday.iso8601 })

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig('details', 'scheduled_at').join).to include('does not work')
    end

    it 'lets the bot reschedule an appointment of its account' do
      post "/api/v1/accounts/#{account.id}/appointments", params: params, headers: headers, as: :json
      appointment_id = response.parsed_body['id']
      later = next_monday_at_ten + 3.hours

      patch "/api/v1/accounts/#{account.id}/appointments/#{appointment_id}", headers: headers, as: :json,
                                                                              params: { appointment: { scheduled_at: later.iso8601 } }
      expect(response).to have_http_status(:success)
      expect(Appointment.find(appointment_id).scheduled_at).to be_within(1.second).of(later)
    end

    it 'keeps delete closed for bots' do
      appointment = Appointment.create!(contact: contact, account: account, owner: owner, appointment_type: 'physical_visit',
                                        location: 'Clínica', scheduled_at: next_monday_at_ten)
      delete "/api/v1/accounts/#{account.id}/appointments/#{appointment.id}", headers: headers, as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
