class Whatsapp::TemplateVariableResolver
  pattr_initialize [:contact!, :account!]

  def resolve(value)
    case value
    when Hash
      value.transform_values { |v| resolve(v) }
    when Array
      value.map { |v| resolve(v) }
    when String
      resolve_string(value)
    else
      value
    end
  end

  private

  def resolve_string(value)
    value.gsub(/\{\{([^}]+)\}\}/) { resolve_variable(Regexp.last_match(1).strip) }
  end

  def resolve_variable(variable_path)
    scope, attribute = variable_path.split('.', 2)

    case scope
    when 'contact'
      contact.send(attribute)
    when 'account'
      account.send(attribute)
    when 'custom_attr'
      contact.custom_attributes&.dig(attribute)
    else
      "[Unknown variable: #{variable_path}]"
    end.to_s
  rescue StandardError => e
    Rails.logger.error "Failed to resolve variable #{variable_path}: #{e.message}"
    "[Error: #{variable_path}]"
  end
end
