module Accounts
  class SetupNautoWebhooksService
    WEBHOOKS = [
      { subscription: 'faq_catalog_updated', path: '/sync/faqs', name: 'Catálogo de FAQs Actualizado' },
      { subscription: 'product_catalog_updated', path: '/sync/products_catalog', name: 'Catálogo de Productos Actualizado' },
      { subscription: 'kb_resource_updated', path: '/sync/knowledge', name: 'Recurso de Base de Conocimiento Actualizado' }
    ].freeze

    def initialize(account)
      @account = account
    end

    def perform
      return setup_nauto_agents if use_nauto_agents?

      base_url = ENV.fetch('NAUTO_ASSISTANT_URL', nil)
      return if base_url.blank?

      WEBHOOKS.each do |config|
        @account.webhooks.create(
          name: config[:name],
          url: "#{base_url}#{config[:path]}",
          subscriptions: [config[:subscription]]
        )
      end

      AgentBot.create(
        account: @account,
        name: "#{@account.name} AI",
        outgoing_url: "#{base_url}/unified_webhook"
      )
    end

    private

    # NEW_ACCOUNTS_AI_BACKEND=nauto_agents + NAUTO_AGENTS_URL: el bot de las cuentas nuevas apunta a
    # nauto-agents. Sin esas variables se mantiene nauto-assistant.
    def use_nauto_agents?
      ENV.fetch('NEW_ACCOUNTS_AI_BACKEND', 'nauto_assistant') == 'nauto_agents' && ENV['NAUTO_AGENTS_URL'].present?
    end

    # nauto-agents consulta FAQs y catálogo en vivo con el token del bot: no usa los webhooks /sync/*.
    def setup_nauto_agents
      AgentBot.create(
        account: @account,
        name: "#{@account.name} AI",
        outgoing_url: "#{ENV.fetch('NAUTO_AGENTS_URL').chomp('/')}/webhook"
      )
    end
  end
end
