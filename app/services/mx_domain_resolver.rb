# frozen_string_literal: true

require "resolv"

class MXDomainResolver

  def initialize(recipient_domain:)
    @recipient_domain = recipient_domain
  end

  def self.resolve(recipient_domain)
    new(recipient_domain: recipient_domain).call
  end

  def call
    return nil if @recipient_domain.blank?

    # Check cache first
    cache = MXDomainCache.find_by(recipient_domain: @recipient_domain)
    if cache && !cache.expired?
      return cache.mx_domain
    end

    # Resolve via DNS
    mx_domain = resolve_mx_domain
    cache_mx_domain(mx_domain) if mx_domain.present?
    mx_domain
  rescue StandardError => e
    logger.error "Failed to resolve MX domain for #{@recipient_domain}: #{e.message}"
    @recipient_domain # Fallback to recipient domain
  end

  private

  def resolve_mx_domain
    resolver = Resolv::DNS.new
    mx_records = resolver.getresources(@recipient_domain, Resolv::DNS::Resource::IN::MX)

    return nil if mx_records.empty?

    # Get primary MX (lowest preference number)
    primary_mx = mx_records.min_by(&:preference)
    mx_hostname = primary_mx.exchange.to_s

    # Extract main domain from MX hostname
    extract_main_domain(mx_hostname)
  ensure
    resolver&.close
  end

  def extract_main_domain(mx_hostname)
    # Remove trailing dot if present
    hostname = mx_hostname.sub(/\.$/, "")

    # Split into parts
    parts = hostname.split(".")

    # Get last 2 parts (domain.tld)
    # Examples:
    #   gmail-smtp-in.l.google.com → google.com
    #   mx1.example.com → example.com
    #   mail.example.co.uk → example.co.uk (note: this is imperfect without public_suffix gem)
    if parts.length >= 2
      parts.last(2).join(".")
    else
      hostname
    end
  end

  def cache_mx_domain(mx_domain)
    ttl = MXDomainCache.cache_ttl
    cache = MXDomainCache.find_or_initialize_by(recipient_domain: @recipient_domain)
    cache.mx_domain = mx_domain
    cache.mx_records = [] # Could store full MX records if needed in future
    cache.resolved_at = Time.current
    cache.expires_at = ttl.seconds.from_now
    cache.save!
  end

  def logger
    Postal.logger
  end

end
