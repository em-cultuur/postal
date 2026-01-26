# frozen_string_literal: true

# DNS cache for MX record lookups
# Provides an in-memory cache with TTL support to reduce DNS query load
# during rate limiting decisions
class MXDNSCache

  # Default TTL in seconds
  DEFAULT_TTL = 3600

  class << self

    # Get cached MX records for a domain
    #
    # @param domain [String] the domain to lookup
    # @param resolver [DNSResolver] the DNS resolver instance
    # @param ttl [Integer] cache TTL in seconds
    # @return [Array<Array<Integer, String>>] MX records [[preference, exchange], ...]
    def mx_records(domain, resolver, ttl: DEFAULT_TTL)
      cache_key = cache_key_for(domain)

      # Check if we have a valid cached result
      if cache.key?(cache_key)
        entry = cache[cache_key]
        return entry[:data] if entry[:expires_at] > Time.current
      end

      # Cache miss - resolve and cache
      begin
        records = resolver.mx(domain)
        cache[cache_key] = {
          data: records,
          expires_at: Time.current + ttl.seconds
        }
        records
      rescue StandardError => e
        # Cache the error for a shorter period to allow recovery attempts
        cache[cache_key] = {
          data: [],
          expires_at: Time.current + 60.seconds,
          error: true
        }
        raise e
      end
    end

    # Get the primary (lowest preference) MX record
    #
    # @param domain [String] the domain to lookup
    # @param resolver [DNSResolver] the DNS resolver instance
    # @param ttl [Integer] cache TTL in seconds
    # @return [String, nil] the primary MX hostname or nil if none found
    def primary_mx(domain, resolver, ttl: DEFAULT_TTL)
      records = mx_records(domain, resolver, ttl: ttl)
      records.first&.last
    end

    # Clear cache entry for a domain
    #
    # @param domain [String] the domain to clear
    # @return [Boolean] true if cleared, false if not in cache
    def clear(domain)
      cache_key = cache_key_for(domain)
      cache.delete(cache_key).present?
    end

    # Clear all cached entries
    #
    # @return [Integer] number of entries cleared
    def clear_all
      size = cache.size
      cache.clear
      size
    end

    # Get cache statistics
    #
    # @return [Hash] statistics about cache usage
    def stats
      {
        size: cache.size,
        entries: cache.map do |key, entry|
          {
            domain: key,
            expires_in: (entry[:expires_at] - Time.current).round,
            expired: entry[:expires_at] <= Time.current,
            has_error: entry[:error] || false
          }
        end
      }
    end

    private

    # Thread-safe cache storage
    def cache
      @cache ||= {}
      @cache_mutex ||= Mutex.new
      @cache
    end

    # Generate cache key from domain
    def cache_key_for(domain)
      domain&.downcase
    end

  end

end
