# agent_bots.secret aparece en schema.rb (sincronizado de otra base) pero ninguna migración lo crea.
# Se usa para firmar con HMAC los webhooks del Agent Bot (AgentBots::WebhookSigner).
class AddSecretToAgentBots < ActiveRecord::Migration[7.1]
  def change
    add_column :agent_bots, :secret, :string unless column_exists?(:agent_bots, :secret)
  end
end
