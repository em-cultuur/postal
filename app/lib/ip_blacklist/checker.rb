# frozen_string_literal: true

module IPBlacklist
  class Checker

    # List of DNSBLs to check
    DNSBLS = [
      { name: "spamhaus_zen", host: "zen.spamhaus.org" },
      { name: "spamhaus_sbl", host: "sbl.spamhaus.org" },
      { name: "spamhaus_xbl", host: "xbl.spamhaus.org" },
      { name: "spamhaus_pbl", host: "pbl.spamhaus.org" },
      { name: "spamcop", host: "bl.spamcop.net" },
      { name: "barracuda", host: "b.barracudacentral.org" },
      { name: "sorbs", host: "dnsbl.sorbs.net" },
      { name: "uribl", host: "multi.uribl.com" },
      { name: "surbl", host: "multi.surbl.org" },
      { name: "psbl", host: "psbl.surriel.com" },
      { name: "mailspike", host: "bl.mailspike.net" },
    ].freeze

    attr_reader :ip_address, :logger

    def initialize(ip_address, logger: Rails.logger)
      @ip_address = ip_address
      @logger = logger
    end

    # Check all DNSBLs for this IP
    def check_all_dnsbls
      DNSBLS.each do |dnsbl|
        check_dnsbl(dnsbl)
        sleep 0.1 # Rate limiting to avoid overwhelming DNSBL servers
      end
    end

    # Check a specific DNSBL
    def check_dnsbl(dnsbl)
      result = query_dnsbl(@ip_address.ipv4, dnsbl[:host])

      if result[:listed]
        handle_blacklist_detected(dnsbl[:name], result)
      else
        handle_not_listed(dnsbl[:name])
      end
    rescue StandardError => e
      logger.error "[BLACKLIST CHECK] Error checking #{dnsbl[:name]} for #{@ip_address.ipv4}: #{e.message}"
    end

    # Re-check a specific blacklist record to see if it's been delisted
    def recheck_specific_blacklist(blacklist_record)
      dnsbl = DNSBLS.find { |d| d[:name] == blacklist_record.blacklist_source }
      return { listed: false, error: "DNSBL not found" } unless dnsbl

      result = query_dnsbl(@ip_address.ipv4, dnsbl[:host])

      blacklist_record.update!(
        last_checked_at: Time.current,
        check_count: blacklist_record.check_count + 1
      )

      if result[:listed]
        # IP is still/again blacklisted
        if blacklist_record.status == IPBlacklistRecord::RESOLVED
          logger.warn "[BLACKLIST CHECK] IP #{@ip_address.ipv4} re-blacklisted on #{dnsbl[:name]}"
          blacklist_record.update!(
            status: IPBlacklistRecord::ACTIVE,
            resolved_at: nil
          )
          # Trigger health manager for re-blacklisting
          IPBlacklist::IPHealthManager.handle_blacklist_detected(blacklist_record)
        else
          logger.info "[BLACKLIST CHECK] IP #{@ip_address.ipv4} still listed on #{dnsbl[:name]}"
        end
      else
        logger.info "[BLACKLIST CHECK] IP #{@ip_address.ipv4} no longer listed on #{dnsbl[:name]}"
      end

      # Return result for caller
      result
    end

    private

    # Query a DNSBL server for the IP
    def query_dnsbl(ip, dnsbl_host)
      reversed_ip = ip.split(".").reverse.join(".")
      lookup_host = "#{reversed_ip}.#{dnsbl_host}"

      begin
        result = Resolv::DNS.open do |dns|
          dns.getaddress(lookup_host)
        end

        { listed: true, result: result.to_s, lookup_host: lookup_host }
      rescue Resolv::ResolvError
        { listed: false, lookup_host: lookup_host }
      end
    end

    # Handle when IP is detected on a blacklist
    def handle_blacklist_detected(source, result)
      logger.warn "[BLACKLIST DETECTED] IP #{@ip_address.ipv4} is listed on #{source}"

      # Infer affected domains from recent sends
      destination_domains = infer_affected_domains

      destination_domains.each do |domain|
        record = IPBlacklistRecord.find_or_initialize_by(
          ip_address: @ip_address,
          destination_domain: domain,
          blacklist_source: source
        )

        if record.new_record?
          record.assign_attributes(
            status: IPBlacklistRecord::ACTIVE,
            detected_at: Time.current,
            last_checked_at: Time.current,
            check_count: 1,
            details: result.to_json
          )
          record.save!

          logger.warn "[BLACKLIST DETECTED] Created new blacklist record for IP #{@ip_address.ipv4}, source: #{source}, domain: #{domain}"

          # Trigger automated actions through IPHealthManager
          IPBlacklist::IPHealthManager.handle_blacklist_detected(record)
        else
          # Already exists, just update check info
          record.update!(
            last_checked_at: Time.current,
            check_count: record.check_count + 1
          )
          logger.info "[BLACKLIST CHECK] Updated existing blacklist record for IP #{@ip_address.ipv4}, source: #{source}, domain: #{domain}"
        end
      end
    end

    # Handle when IP is not listed (or has been delisted)
    def handle_not_listed(source)
      # Check if there were active records that should be resolved
      IPBlacklistRecord
        .where(ip_address: @ip_address, blacklist_source: source, status: IPBlacklistRecord::ACTIVE)
        .find_each do |record|
          logger.info "[BLACKLIST RESOLVED] IP #{@ip_address.ipv4} no longer listed on #{source} for domain #{record.destination_domain}"
          record.mark_resolved!
        end
    end

    # Infer which destination domains might be affected
    # This queries the message database to find recent recipient domains
    def infer_affected_domains
      domains = []

      # Get domains from recent messages sent using this IP
      # We look back 7 days to get a good sample
      Server.find_each do |server|
        next unless server.message_db

        begin
          # Query the message database for recent recipient domains
          sql = <<-SQL
            SELECT DISTINCT SUBSTRING_INDEX(rcpt_to, '@', -1) as domain
            FROM messages
            WHERE ip_address_id = ?
            AND timestamp > ?
            ORDER BY timestamp DESC
            LIMIT 50
          SQL

          results = server.message_db.select_all(
            ActiveRecord::Base.sanitize_sql_array([sql, @ip_address.id, 7.days.ago])
          )

          server_domains = results.map { |row| row["domain"] }.compact.map(&:downcase)
          domains.concat(server_domains)
        rescue StandardError => e
          logger.error "[BLACKLIST CHECK] Error querying message DB for server #{server.id}: #{e.message}"
        end
      end

      # Return unique domains, or use wildcard if we couldn't determine any
      unique_domains = domains.uniq
      if unique_domains.empty?
        logger.warn "[BLACKLIST CHECK] Could not determine affected domains for IP #{@ip_address.ipv4}, using wildcard"
        ["*"] # Wildcard means all domains
      else
        logger.info "[BLACKLIST CHECK] Inferred #{unique_domains.count} affected domains for IP #{@ip_address.ipv4}"
        unique_domains
      end
    end

  end
end
