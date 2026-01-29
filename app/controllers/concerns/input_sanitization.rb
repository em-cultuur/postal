# frozen_string_literal: true

# Input Sanitization Concern
# Provides methods for validating and sanitizing user input
module InputSanitization

  extend ActiveSupport::Concern

  # Maximum lengths for various input fields
  REASON_MAX_LENGTH = 500
  DOMAIN_MAX_LENGTH = 255

  # Allowed characters for reason field (letters, numbers, basic punctuation)
  REASON_REGEX = /\A[\p{L}\p{N}\s\-_.,;:()\[\]\/\\'"]+\z/u

  # Domain name validation (RFC compliant)
  DOMAIN_REGEX = /\A(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9][a-z0-9-]{0,61}[a-z0-9]\z/i

  private

  # Sanitize and validate a reason string
  # @param input [String] The raw input string
  # @param default [String] Default value if input is blank
  # @return [String] Sanitized reason string
  def sanitize_reason(input, default: "Action by #{current_user.name}")
    reason = input.to_s.strip

    # Use default if empty
    reason = default if reason.blank?

    # Truncate to maximum length
    reason = reason.truncate(REASON_MAX_LENGTH, omission: "...")

    # Remove control characters and normalize whitespace
    reason = reason.gsub(/[[:cntrl:]]/, "").squeeze(" ")

    # Validate allowed characters
    unless reason.match?(REASON_REGEX)
      raise ArgumentError, "Reason contains invalid characters. Only letters, numbers, and basic punctuation allowed."
    end

    reason
  end

  # Sanitize and validate a domain name
  # @param input [String] The raw domain input
  # @return [String, nil] Sanitized domain or nil if invalid
  def sanitize_domain(input)
    return nil if input.blank?

    domain = input.to_s.strip.downcase

    # Truncate to maximum length
    domain = domain[0, DOMAIN_MAX_LENGTH]

    # Remove any invalid characters
    domain = domain.gsub(/[^a-z0-9.-]/, "")

    # Validate format
    unless domain.match?(DOMAIN_REGEX)
      raise ArgumentError, "Invalid domain name format"
    end

    domain
  rescue ArgumentError => e
    Rails.logger.warn "[INPUT SANITIZATION] Domain validation failed: #{e.message}"
    nil
  end

  # Sanitize integer parameter
  # @param input [String, Integer] The raw input
  # @param min [Integer] Minimum allowed value
  # @param max [Integer] Maximum allowed value
  # @param default [Integer] Default value if invalid
  # @return [Integer] Sanitized integer
  def sanitize_integer(input, min: 0, max: 1_000_000, default: 0)
    value = input.to_i
    value = default if value < min || value > max
    value
  end

  # Sanitize direction parameter for stage adjustments
  # @param input [String] Direction ('up' or 'down')
  # @return [String, nil] Valid direction or nil
  def sanitize_direction(input)
    direction = input.to_s.strip.downcase
    %w[up down].include?(direction) ? direction : nil
  end

  # Sanitize status parameter
  # @param input [String] Status value
  # @param allowed [Array<String>] List of allowed statuses
  # @return [String, nil] Valid status or nil
  def sanitize_status(input, allowed:)
    status = input.to_s.strip.downcase
    allowed.include?(status) ? status : nil
  end

  # Sanitize pagination parameters
  # @param page [String, Integer] Page number
  # @param per_page [String, Integer] Items per page
  # @return [Hash] Hash with :page and :per_page keys
  def sanitize_pagination_params(page: nil, per_page: nil)
    {
      page: sanitize_integer(page || 1, min: 1, max: 10_000, default: 1),
      per_page: sanitize_integer(per_page || 50, min: 1, max: 100, default: 50)
    }
  end

end
