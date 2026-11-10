# frozen_string_literal: true

module Rubycog
  # Builds the options for RubyLLM.chat. Self-hosted OpenAI-compatible gateways
  # serve model ids that RubyLLM's registry has never heard of, so a deployment
  # can name the provider and skip the registry lookup instead of teaching the
  # registry about every private model.
  module ChatFactory
    PROVIDER_ENV = 'RUBYCOG_PROVIDER'
    ASSUME_ENV = 'RUBYCOG_ASSUME_MODEL_EXISTS'

    module_function

    # `provider` is a RubyLLM provider name such as "openai"; naming it implies
    # the model exists because a private gateway is the only reason to set it.
    def options(model: nil, env: ENV)
      options = {}
      options[:model] = model if model
      provider = env[PROVIDER_ENV].to_s.strip
      unless provider.empty?
        options[:provider] = provider.to_sym
        options[:assume_model_exists] = true
      end
      options[:assume_model_exists] = true if assume_model_exists?(env)
      options
    end

    def assume_model_exists?(env)
      env[ASSUME_ENV].to_s.strip == '1'
    end
  end
end
