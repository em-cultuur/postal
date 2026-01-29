# frozen_string_literal: true

# Be sure to restart your server when you modify this file.

# Configure parameters to be filtered from the log file. Use this to limit dissemination of
# sensitive information. See the ActiveSupport::ParameterFilter documentation for supported
# notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn,
  # IP Reputation system sensitive data
  :smtp_response_message,  # May contain sensitive email content or server details
  :reason,                 # Admin notes may contain sensitive information
  :raw_message,           # SMTP error messages may reveal infrastructure details
]
