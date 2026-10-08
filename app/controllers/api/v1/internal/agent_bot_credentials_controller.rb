# frozen_string_literal: true

# Credenciales de un Agent Bot para nauto-agents (reemplaza la tabla agents_settings).
# Autenticado con un único token de servicio: Authorization: Bearer <NAUTO_AGENTS_SERVICE_TOKEN>.
class Api::V1::Internal::AgentBotCredentialsController < ApplicationController
  before_action :authenticate_service!

  def show
    agent_bot = AgentBot.find_by(id: params[:agent_bot_id])
    return render json: { error: 'Not found' }, status: :not_found unless agent_bot

    render json: {
      agent_bot_id: agent_bot.id,
      account_id: agent_bot.account_id,
      access_token: agent_bot.access_token&.token,
      secret: agent_bot.ensure_secret!,
      inbox_ids: agent_bot.agent_bot_inboxes.pluck(:inbox_id),
      openai_api_key: agent_bot.openai_api_key.presence,
      google_api_key: agent_bot.google_api_key.presence,
      pinecone_api_key: agent_bot.account&.pinecone_api_key.presence
    }
  end

  private

  def authenticate_service!
    expected = ENV.fetch('NAUTO_AGENTS_SERVICE_TOKEN', nil)
    token = request.headers['Authorization'].to_s.delete_prefix('Bearer ').strip

    authorized = expected.present? && token.present? && ActiveSupport::SecurityUtils.secure_compare(token, expected)
    render json: { error: 'Unauthorized' }, status: :unauthorized unless authorized
  end
end
