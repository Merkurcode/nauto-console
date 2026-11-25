// Constants
export const DEFAULT_LANGUAGE = 'en';
export const DEFAULT_CATEGORY = 'UTILITY';
export const COMPONENT_TYPES = {
  HEADER: 'HEADER',
  BODY: 'BODY',
  BUTTONS: 'BUTTONS',
};
export const MEDIA_FORMATS = ['IMAGE', 'VIDEO', 'DOCUMENT'];

export const findComponentByType = (template, type) =>
  template.components?.find(component => component.type === type);

export const processVariable = str => {
  return str.replace(/{{|}}/g, '');
};

export const allKeysRequired = value => {
  const keys = Object.keys(value);
  return keys.every(key => value[key]);
};

export const replaceTemplateVariables = (templateText, processedParams) => {
  return templateText.replace(/{{([^}]+)}}/g, (match, variable) => {
    const variableKey = processVariable(variable);
    return processedParams.body?.[variableKey] || `{{${variable}}}`;
  });
};

// Replaces {{contact.name}}, {{contact.first_name}}, {{contact.email}},
// {{contact.phone_number}} and {{custom_attr.key}} with the contact's data
export const resolveContactVariables = (text, contact) => {
  const values = {
    'contact.name': contact.name,
    'contact.first_name': contact.name?.split(' ')[0],
    'contact.email': contact.email,
    'contact.phone_number': contact.phone_number,
  };
  return text.replace(/{{\s*([^}]+?)\s*}}/g, (match, variable) => {
    if (variable.startsWith('custom_attr.')) {
      const key = variable.replace('custom_attr.', '');
      return String(contact.custom_attributes?.[key] ?? '');
    }
    return variable in values ? values[variable] || '' : match;
  });
};

export const buildTemplateParameters = (template, hasMediaHeaderValue) => {
  const allVariables = {};

  const bodyComponent = findComponentByType(template, COMPONENT_TYPES.BODY);
  const headerComponent = findComponentByType(template, COMPONENT_TYPES.HEADER);

  if (!bodyComponent) return allVariables;

  const templateString = bodyComponent.text;

  // Process body variables
  const matchedVariables = templateString.match(/{{([^}]+)}}/g);
  if (matchedVariables) {
    allVariables.body = {};
    matchedVariables.forEach(variable => {
      const key = processVariable(variable);
      allVariables.body[key] = '';
    });
  }

  if (hasMediaHeaderValue) {
    if (!allVariables.header) allVariables.header = {};
    allVariables.header.media_url = '';
    allVariables.header.media_type = headerComponent.format.toLowerCase();

    // For document templates, include media_name field for filename support
    if (headerComponent.format.toLowerCase() === 'document') {
      allVariables.header.media_name = '';
    }
  }

  // Process button variables
  const buttonComponents = template.components.filter(
    component => component.type === COMPONENT_TYPES.BUTTONS
  );

  buttonComponents.forEach(buttonComponent => {
    if (buttonComponent.buttons) {
      buttonComponent.buttons.forEach((button, index) => {
        // Handle URL buttons with variables
        if (button.type === 'URL' && button.url && button.url.includes('{{')) {
          const buttonVars = button.url.match(/{{([^}]+)}}/g) || [];
          if (buttonVars.length > 0) {
            if (!allVariables.buttons) allVariables.buttons = [];
            allVariables.buttons[index] = {
              type: 'url',
              parameter: '',
              url: button.url,
              variables: buttonVars.map(v => processVariable(v)),
            };
          }
        }

        // Handle copy code buttons
        if (button.type === 'COPY_CODE') {
          if (!allVariables.buttons) allVariables.buttons = [];
          allVariables.buttons[index] = {
            type: 'copy_code',
            parameter: '',
          };
        }
      });
    }
  });

  return allVariables;
};
