# frozen_string_literal: true

require 'truemail/client'
require 'json'
require 'timeout'

module Postal
  module MessageInspectors
    class Truemail < MessageInspector

      def inspect_message(inspection)
        # Truemail validates email addresses, not message content
        # We extract the To address from the message
        message = inspection.message
        to_address = extract_to_address(message)

        return unless to_address

        begin
          validation_result = validate_email(to_address)

          if validation_result[:success]
            inspection.validation_failed = false
            inspection.validation_message = "Email address validation passed"
            inspection.spam_checks << SpamCheck.new("TRUEMAIL_VALID", 0, "Email address is valid")
          else
            inspection.validation_failed = true
            inspection.validation_message = "Email address validation failed: #{validation_result[:errors]&.join(', ')}"
            inspection.spam_checks << SpamCheck.new("TRUEMAIL_INVALID", 10, validation_result[:errors]&.join(', ') || "Invalid email address")
          end
        rescue Timeout::Error
          inspection.validation_failed = false
          inspection.validation_message = "Timed out validating email address"
          inspection.spam_checks << SpamCheck.new("TRUEMAIL_TIMEOUT", 0, "Email validation timed out")
        rescue StandardError => e
          logger.error "Error talking to Truemail API: #{e.class} (#{e.message})"
          logger.error e.backtrace[0, 5]
          inspection.validation_failed = false
          inspection.validation_message = "Error when validating email address"
          inspection.spam_checks << SpamCheck.new("TRUEMAIL_ERROR", 0, "Error validating email address")
        end
      end

      private

      def extract_to_address(message)
        # Extracts the To address from the message
        if message.respond_to?(:to)
          message.to&.first
        elsif message.respond_to?(:raw_message)
          # Manual parsing of the To header from the raw message
          raw = message.raw_message
          if raw =~ /^To:\s*(.+)$/mi
            $1.strip
          end
        end
      end

      def validate_email(email)
        configure_client

        Timeout.timeout(@config.timeout || 10) do
          response_json = ::Truemail::Client.validate(email)
          response = JSON.parse(response_json)

          {
            success: response['success'] == true,
            errors: extract_errors(response)
          }
        end
      end

      def configure_client
        ::Truemail::Client.configure do |config|
          config.host = @config.host
          config.port = @config.port || 9292
          config.secure_connection = @config.ssl || false
          config.token = @config.token if @config.token.present?
        end
      end

      def extract_errors(response)
        errors = []
        
        if response['success'] == false
          # Check for various error sources in the response
          errors << response['errors'] if response['errors']
          errors << response['truemail_client_error'] if response['truemail_client_error']
          errors << 'Validation failed' if errors.empty?
        end

        errors.flatten.compact
      end

    end
  end
end
