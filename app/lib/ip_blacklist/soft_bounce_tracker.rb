# frozen_string_literal: true

module IPBlacklist
  # Tracks soft bounce events to detect patterns that may indicate blacklisting
  # or reputation issues. Uses Rails cache (configurable backend) for fast counting
  # within time windows.
  #
  # When soft bounces for an IP+domain combination exceed a threshold within
  # a time window, it suggests pausing the IP for that domain.
  #
  # @example Record a soft bounce and check threshold
  #   tracker = IPBlacklist::SoftBounceTracker.new(
  #     ip_address_id: 123,
  #     destination_domain: "gmail.com",
  #     threshold: 5,
  #     window_minutes: 60
  #   )
  #
  #   if tracker.record_and_check_threshold
  #     # Threshold exceeded, take action
  #     IPHealthManager.handle_excessive_soft_bounces(ip, domain)
  #   end
  #
  class SoftBounceTracker

    attr_reader :ip_address_id, :destination_domain, :threshold, :window_minutes

    # Default configuration
    DEFAULT_THRESHOLD = 5
    DEFAULT_WINDOW_MINUTES = 60

    # @param ip_address_id [Integer] The IP address ID
    # @param destination_domain [String] The destination domain (e.g., "gmail.com")
    # @param threshold [Integer] Number of soft bounces to trigger action (default: 5)
    # @param window_minutes [Integer] Time window in minutes (default: 60)
    #
    def initialize(ip_address_id:, destination_domain:, threshold: DEFAULT_THRESHOLD, window_minutes: DEFAULT_WINDOW_MINUTES)
      @ip_address_id = ip_address_id
      @destination_domain = destination_domain
      @threshold = threshold
      @window_minutes = window_minutes
    end

    # Records a soft bounce event and checks if threshold is exceeded
    #
    # @return [Boolean] true if threshold is exceeded, false otherwise
    #
    def record_and_check_threshold
      increment_counter
      count = current_count
      count >= threshold
    end

    # Records a soft bounce without checking threshold
    #
    # @return [Integer] The new count
    #
    def record
      increment_counter
      current_count
    end

    # Gets the current count of soft bounces within the time window
    #
    # @return [Integer] The count
    #
    def current_count
      Rails.cache.read(cache_key) || 0
    end

    # Checks if the threshold is currently exceeded
    #
    # @return [Boolean] true if threshold is exceeded
    #
    def threshold_exceeded?
      current_count >= threshold
    end

    # Resets the counter (useful after taking action)
    #
    # @return [Boolean] true if reset succeeded
    #
    def reset
      Rails.cache.delete(cache_key)
    end

    # Gets the time until the counter expires
    #
    # @return [Integer, nil] Seconds until expiry, or nil if not set
    #
    def time_until_expiry
      # Rails.cache doesn't provide a direct way to get TTL
      # This is an approximation based on when we expect it to expire
      window_minutes * 60
    end

    # Class method to check threshold for IP+domain combination
    #
    # @param ip_address_id [Integer]
    # @param destination_domain [String]
    # @param threshold [Integer]
    # @param window_minutes [Integer]
    # @return [Boolean] true if threshold is exceeded
    #
    def self.threshold_exceeded?(ip_address_id:, destination_domain:, threshold: DEFAULT_THRESHOLD, window_minutes: DEFAULT_WINDOW_MINUTES)
      new(
        ip_address_id: ip_address_id,
        destination_domain: destination_domain,
        threshold: threshold,
        window_minutes: window_minutes
      ).threshold_exceeded?
    end

    # Class method to record and check in one call
    #
    # @param ip_address_id [Integer]
    # @param destination_domain [String]
    # @param threshold [Integer]
    # @param window_minutes [Integer]
    # @return [Boolean] true if threshold is exceeded after recording
    #
    def self.record_and_check(ip_address_id:, destination_domain:, threshold: DEFAULT_THRESHOLD, window_minutes: DEFAULT_WINDOW_MINUTES)
      new(
        ip_address_id: ip_address_id,
        destination_domain: destination_domain,
        threshold: threshold,
        window_minutes: window_minutes
      ).record_and_check_threshold
    end

    # Class method to reset counter
    #
    # @param ip_address_id [Integer]
    # @param destination_domain [String]
    # @return [Boolean]
    #
    def self.reset(ip_address_id:, destination_domain:)
      new(
        ip_address_id: ip_address_id,
        destination_domain: destination_domain
      ).reset
    end

    private

    # Generates the cache key for this IP+domain combination
    # Security: Hash domain name to prevent cache key collision attacks
    #
    # @return [String]
    #
    def cache_key
      # Normalize domain to lowercase and hash it to prevent:
      # 1. Cache key collision attacks (e.g., "gmail.com" vs "gmail..com")
      # 2. Cache poisoning via specially crafted domain names
      # 3. Key length issues with very long domains
      domain_normalized = destination_domain.to_s.downcase.strip
      domain_hash = Digest::SHA256.hexdigest(domain_normalized)

      # Version the cache key to allow invalidation if format changes
      "ip_blacklist:soft_bounce:v1:#{ip_address_id}:#{domain_hash}"
    end

    # Increments the counter with expiry
    #
    # @return [Integer] The new count
    #
    def increment_counter
      # Use increment with expires_in to auto-expire old counters
      current = Rails.cache.read(cache_key) || 0
      new_value = current + 1

      # Set with expiry (Rails.cache.increment doesn't support expires_in in all backends)
      Rails.cache.write(cache_key, new_value, expires_in: window_minutes.minutes)

      new_value
    end

  end
end
