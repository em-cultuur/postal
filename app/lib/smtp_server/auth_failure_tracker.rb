# frozen_string_literal: true

module SMTPServer
  # Tracks authentication failures to detect and block brute force attacks.
  # Uses Rails cache for fast counting within time windows and tracks both
  # failure counts and active blocks.
  #
  # After X failed authentication attempts within a time window, the source IP
  # is blocked for Y minutes. Both X (threshold) and Y (block duration) are
  # configurable.
  #
  # @example Check if IP is blocked
  #   tracker = SMTPServer::AuthFailureTracker.new(ip_address: "1.2.3.4")
  #   if tracker.blocked?
  #     # Reject connection
  #   end
  #
  # @example Record a failed authentication attempt
  #   tracker = SMTPServer::AuthFailureTracker.new(
  #     ip_address: "1.2.3.4",
  #     threshold: 5,
  #     block_duration_minutes: 120
  #   )
  #
  #   if tracker.record_failure_and_check_threshold
  #     # Threshold exceeded, IP is now blocked
  #     logger.warn "IP #{ip_address} blocked after #{threshold} failed attempts"
  #   end
  #
  class AuthFailureTracker

    attr_reader :ip_address, :threshold, :block_duration_minutes

    # Default configuration
    # After 5 failed attempts, block for 120 minutes (2 hours)
    DEFAULT_THRESHOLD = 5
    DEFAULT_BLOCK_DURATION_MINUTES = 120
    DEFAULT_WINDOW_MINUTES = 15

    # @param ip_address [String] The source IP address
    # @param threshold [Integer] Number of failures to trigger block (default: 5)
    # @param block_duration_minutes [Integer] How long to block the IP (default: 120)
    # @param window_minutes [Integer] Time window for counting failures (default: 15)
    #
    def initialize(ip_address:, threshold: nil, block_duration_minutes: nil, window_minutes: nil)
      @ip_address = ip_address
      @threshold = threshold || config_threshold || DEFAULT_THRESHOLD
      @block_duration_minutes = block_duration_minutes || config_block_duration || DEFAULT_BLOCK_DURATION_MINUTES
      @window_minutes = window_minutes || DEFAULT_WINDOW_MINUTES
    end

    # Checks if the IP is currently blocked
    #
    # @return [Boolean] true if IP is blocked
    #
    def blocked?
      Rails.cache.read(block_cache_key).present?
    end

    # Records a failed authentication attempt and checks if threshold is exceeded.
    # If threshold is exceeded, blocks the IP.
    #
    # @return [Boolean] true if threshold is exceeded and IP is now blocked
    #
    def record_failure_and_check_threshold
      increment_failure_counter
      count = current_failure_count

      if count >= @threshold
        block_ip
        true
      else
        false
      end
    end

    # Records a failed authentication without checking threshold
    #
    # @return [Integer] The new failure count
    #
    def record_failure
      increment_failure_counter
      current_failure_count
    end

    # Gets the current count of failed attempts within the time window
    #
    # @return [Integer] The count
    #
    def current_failure_count
      Rails.cache.read(failure_cache_key) || 0
    end

    # Records a successful authentication (clears failure counter)
    #
    # @return [Boolean] true if reset succeeded
    #
    def record_success
      reset_failure_counter
    end

    # Blocks the IP address for the configured duration
    #
    # @return [Boolean] true if block was set
    #
    def block_ip
      # Add IP to blocked index
      add_to_blocked_index

      Rails.cache.write(
        block_cache_key,
        {
          ip_address: @ip_address,
          blocked_at: Time.current.to_i,
          failure_count: current_failure_count,
          threshold: @threshold
        },
        expires_in: @block_duration_minutes.minutes
      )
    end

    # Manually unblocks an IP address (e.g., for administrative override)
    #
    # @return [Boolean] true if unblock succeeded
    #
    def unblock_ip
      # Remove from blocked index
      remove_from_blocked_index

      Rails.cache.delete(block_cache_key)
    end

    # Resets the failure counter
    #
    # @return [Boolean] true if reset succeeded
    #
    def reset_failure_counter
      Rails.cache.delete(failure_cache_key)
    end

    # Gets block information if IP is blocked
    #
    # @return [Hash, nil] Block info hash with :blocked_at, :failure_count, :threshold, or nil
    #
    def block_info
      Rails.cache.read(block_cache_key)
    end

    # Gets the time remaining on the block in seconds
    #
    # @return [Integer, nil] Seconds remaining, or nil if not blocked
    #
    def time_remaining_on_block
      return nil unless blocked?

      # Rails.cache doesn't provide direct TTL access, so we estimate
      # based on blocked_at timestamp if available
      info = block_info
      return @block_duration_minutes * 60 unless info&.dig(:blocked_at)

      elapsed = Time.current.to_i - info[:blocked_at]
      remaining = (@block_duration_minutes * 60) - elapsed
      [remaining, 0].max
    end

    # Class method to check if an IP is blocked
    #
    # @param ip_address [String]
    # @return [Boolean]
    #
    def self.blocked?(ip_address)
      new(ip_address: ip_address).blocked?
    end

    # Class method to record failure and check threshold
    #
    # @param ip_address [String]
    # @param threshold [Integer]
    # @param block_duration_minutes [Integer]
    # @return [Boolean] true if IP is now blocked
    #
    def self.record_and_check(ip_address:, threshold: nil, block_duration_minutes: nil)
      new(
        ip_address: ip_address,
        threshold: threshold,
        block_duration_minutes: block_duration_minutes
      ).record_failure_and_check_threshold
    end

    # Class method to unblock an IP
    #
    # @param ip_address [String]
    # @return [Boolean]
    #
    def self.unblock(ip_address)
      new(ip_address: ip_address).unblock_ip
    end

    # Class method to get all blocked IPs with their information
    #
    # @return [Array<Hash>] Array of hashes with IP info
    #
    def self.all_blocked
      blocked_ips_set = Rails.cache.read(blocked_index_key) || []

      blocked_ips_set.map do |ip|
        tracker = new(ip_address: ip)
        info = tracker.block_info

        next nil unless info # Skip if expired

        {
          ip_address: ip,
          blocked_at: Time.at(info[:blocked_at]),
          failure_count: info[:failure_count],
          threshold: info[:threshold],
          expires_at: Time.at(info[:blocked_at]) + (tracker.block_duration_minutes * 60),
          time_remaining: tracker.time_remaining_on_block
        }
      end.compact.sort_by { |b| -b[:blocked_at].to_i }
    end

    # Class method to search blocked IPs
    #
    # @param query [String] IP address or partial IP to search for
    # @return [Array<Hash>] Array of matching blocked IPs
    #
    def self.search_blocked(query)
      return all_blocked if query.blank?

      all_blocked.select { |b| b[:ip_address].include?(query) }
    end

    # Class method to clean expired entries from blocked index
    #
    # @return [Integer] Number of cleaned entries
    #
    def self.cleanup_blocked_index
      blocked_ips_set = Rails.cache.read(blocked_index_key) || []
      cleaned = 0

      blocked_ips_set.reject! do |ip|
        tracker = new(ip_address: ip)
        is_expired = !tracker.blocked?
        cleaned += 1 if is_expired
        is_expired
      end

      Rails.cache.write(blocked_index_key, blocked_ips_set)
      cleaned
    end

    # Cache key for the blocked IPs index
    #
    # @return [String]
    #
    def self.blocked_index_key
      "smtp_auth:blocked_index:v1"
    end

    private

    # Generates the cache key for failure counting
    #
    # @return [String]
    #
    def failure_cache_key
      # Hash IP to prevent cache key manipulation and normalize length
      ip_hash = Digest::SHA256.hexdigest(@ip_address.to_s)
      "smtp_auth:failures:v1:#{ip_hash}"
    end

    # Generates the cache key for blocking
    #
    # @return [String]
    #
    def block_cache_key
      # Hash IP to prevent cache key manipulation and normalize length
      ip_hash = Digest::SHA256.hexdigest(@ip_address.to_s)
      "smtp_auth:blocked:v1:#{ip_hash}"
    end

    # Increments the failure counter with expiry
    #
    # @return [Integer] The new count
    #
    def increment_failure_counter
      current = Rails.cache.read(failure_cache_key) || 0
      new_value = current + 1

      # Set with expiry to auto-expire old counters
      Rails.cache.write(failure_cache_key, new_value, expires_in: @window_minutes.minutes)

      new_value
    end

    # Reads threshold from configuration
    #
    # @return [Integer, nil]
    #
    def config_threshold
      return nil unless defined?(Postal::Config)

      Postal::Config.smtp_server&.auth_failure_threshold
    rescue StandardError
      nil
    end

    # Reads block duration from configuration
    #
    # @return [Integer, nil]
    #
    def config_block_duration
      return nil unless defined?(Postal::Config)

      Postal::Config.smtp_server&.auth_failure_block_duration
    rescue StandardError
      nil
    end

    # Adds IP to the blocked index
    #
    # @return [Boolean]
    #
    def add_to_blocked_index
      blocked_ips_set = Rails.cache.read(self.class.blocked_index_key) || []
      blocked_ips_set << @ip_address unless blocked_ips_set.include?(@ip_address)
      Rails.cache.write(self.class.blocked_index_key, blocked_ips_set)
    end

    # Removes IP from the blocked index
    #
    # @return [Boolean]
    #
    def remove_from_blocked_index
      blocked_ips_set = Rails.cache.read(self.class.blocked_index_key) || []
      blocked_ips_set.delete(@ip_address)
      Rails.cache.write(self.class.blocked_index_key, blocked_ips_set)
    end

  end
end
