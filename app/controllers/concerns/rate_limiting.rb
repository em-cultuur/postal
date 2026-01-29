# frozen_string_literal: true

# Rate Limiting Concern
# Provides rate limiting functionality to prevent abuse of expensive operations
#
# @example Usage in a controller
#   class MyController < ApplicationController
#     include RateLimiting
#
#     before_action :rate_limit_recheck, only: [:recheck]
#
#     def recheck
#       # Expensive operation that queries external services
#     end
#   end
#
module RateLimiting

  extend ActiveSupport::Concern

  # Default rate limit configuration
  RATE_LIMIT_CONFIG = {
    recheck: { limit: 3, window: 1.hour },
    dns_query: { limit: 10, window: 1.minute },
    api_call: { limit: 60, window: 1.minute }
  }.freeze

  # Rate limit the recheck action (DNS queries are expensive)
  # Limits: 3 requests per hour per record per user
  def rate_limit_recheck
    rate_limit(
      action: "recheck",
      scope: [@record.id, current_user.id],
      limit: RATE_LIMIT_CONFIG[:recheck][:limit],
      window: RATE_LIMIT_CONFIG[:recheck][:window]
    )
  end

  # Generic rate limiting method
  #
  # @param action [String] The action being rate limited
  # @param scope [Array] Array of identifiers to scope the rate limit (e.g., [record_id, user_id])
  # @param limit [Integer] Maximum number of requests allowed
  # @param window [ActiveSupport::Duration] Time window for the rate limit
  # @return [Boolean] true if within limit, renders error response if exceeded
  def rate_limit(action:, scope:, limit:, window:)
    cache_key = build_rate_limit_key(action, scope)

    # Get current count from cache
    count = Rails.cache.read(cache_key) || 0

    if count >= limit
      Rails.logger.warn "[RATE LIMIT] User #{current_user&.id} exceeded limit for #{action} (#{count}/#{limit})"

      respond_to do |format|
        format.html do
          redirect_back(
            fallback_location: root_path,
            alert: "Rate limit exceeded. Maximum #{limit} #{action} requests per #{humanize_duration(window)}. Please try again later."
          )
        end
        format.json do
          render json: {
            error: "Rate limit exceeded",
            limit: limit,
            window: window.to_i,
            retry_after: window.to_i
          }, status: :too_many_requests
        end
      end

      return false
    end

    # Increment counter
    Rails.cache.write(cache_key, count + 1, expires_in: window)
    true
  end

  private

  # Build a unique cache key for rate limiting
  #
  # @param action [String] The action being rate limited
  # @param scope [Array] Array of identifiers to scope the rate limit
  # @return [String] Cache key
  def build_rate_limit_key(action, scope)
    scope_str = scope.map(&:to_s).join(":")
    "rate_limit:#{action}:#{scope_str}"
  end

  # Convert duration to human-readable format
  #
  # @param duration [ActiveSupport::Duration] Duration to humanize
  # @return [String] Human-readable duration
  def humanize_duration(duration)
    seconds = duration.to_i

    return "#{seconds / 3600} hour#{'s' if seconds / 3600 != 1}" if seconds >= 3600
    return "#{seconds / 60} minute#{'s' if seconds / 60 != 1}" if seconds >= 60

    "#{seconds} second#{'s' if seconds != 1}"
  end

end
