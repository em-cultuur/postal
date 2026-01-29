# frozen_string_literal: true

module IPBlacklist
  class IPHealthManager

    class << self

      # Handle when a blacklist is detected for this IP
      def handle_blacklist_detected(blacklist_record)
        ip_address = blacklist_record.ip_address
        domain = blacklist_record.destination_domain

        # Create or update exclusion
        exclusion = IPDomainExclusion.find_or_initialize_by(
          ip_address: ip_address,
          destination_domain: domain
        )

        if exclusion.new_record?
          exclusion.assign_attributes(
            excluded_at: Time.current,
            reason: "Blacklisted on #{blacklist_record.blacklist_source}",
            warmup_stage: 0,
            ip_blacklist_record: blacklist_record
          )
          exclusion.save!

          Rails.logger.warn "[IP HEALTH] IP #{ip_address.ipv4} blacklisted on #{blacklist_record.blacklist_source} for domain #{domain}"
        else
          # If already excluded, update reason to include new blacklist
          current_reason = exclusion.reason || ""
          new_source = blacklist_record.blacklist_source

          unless current_reason.include?(new_source)
            exclusion.update!(
              reason: "#{current_reason}; #{new_source}".strip.sub(/^;/, ""),
              warmup_stage: 0, # Reset to paused if it was warming up
              next_warmup_at: nil
            )
          end

          Rails.logger.warn "[IP HEALTH] Updated exclusion for IP #{ip_address.ipv4} on domain #{domain}, reset to stage 0"
        end

        # Log the pause action
        IPHealthAction.create!(
          ip_address: ip_address,
          action_type: IPHealthAction::PAUSE,
          destination_domain: domain,
          reason: "IP blacklisted on #{blacklist_record.blacklist_source}",
          previous_priority: ip_address.priority,
          new_priority: 0,
          user_id: nil, # nil = automated
          triggered_by_blacklist_id: blacklist_record.id
        )

        Rails.logger.warn "[IP HEALTH] Paused IP #{ip_address.ipv4} for domain #{domain} (blacklist: #{blacklist_record.blacklist_source})"

        # Send notification using Notifier
        notifier = IPBlacklist::Notifier.new
        action = IPHealthAction.where(ip_address: ip_address, triggered_by_blacklist_id: blacklist_record.id).last
        notifier.notify_blacklist_detected(ip_address, blacklist_record)
        notifier.notify_ip_paused(ip_address, domain, "Blacklisted on #{blacklist_record.blacklist_source}", action) if action

        # Check if we need to trigger rotation
        check_rotation_possibility(blacklist_record)
      end

      # Start warmup process after blacklist is resolved
      def start_warmup(ip_address, destination_domain)
        exclusion = IPDomainExclusion.find_by(
          ip_address: ip_address,
          destination_domain: destination_domain
        )

        unless exclusion
          Rails.logger.error "[WARMUP] Exclusion not found for IP #{ip_address.ipv4} and domain #{destination_domain}"
          return
        end

        # Advance to stage 1 (priority 20) for 2 days
        exclusion.advance_warmup_stage!

        Rails.logger.info "[WARMUP] Starting warmup for IP #{ip_address.ipv4} on domain #{destination_domain} - Stage 1 (Priority 20)"
      end

      # Manually unpause an IP for a domain (admin override)
      def unpause_for_domain(ip_address, destination_domain, user: nil)
        exclusion = IPDomainExclusion.find_by(
          ip_address: ip_address,
          destination_domain: destination_domain
        )

        unless exclusion
          Rails.logger.info "[IP HEALTH] No exclusion found for IP #{ip_address.ipv4} and domain #{destination_domain}"
          return
        end

        exclusion.destroy!

        action = IPHealthAction.create!(
          ip_address: ip_address,
          action_type: IPHealthAction::UNPAUSE,
          destination_domain: destination_domain,
          reason: "Manual unpause by admin: #{user}",
          previous_priority: exclusion.current_priority,
          new_priority: ip_address.priority,
          user_id: nil # TODO: Look up user by email if needed
        )

        Rails.logger.info "[IP HEALTH] Manual unpause for IP #{ip_address.ipv4} on domain #{destination_domain} by #{user}"

        # Send notification
        notifier = IPBlacklist::Notifier.new
        notifier.notify_ip_resumed(ip_address, destination_domain, action)
      end

      # Manually pause an IP for a domain (admin action)
      def pause_for_domain(ip_address, destination_domain, reason: nil, user: nil)
        exclusion = IPDomainExclusion.find_or_initialize_by(
          ip_address: ip_address,
          destination_domain: destination_domain
        )

        if exclusion.new_record?
          exclusion.assign_attributes(
            excluded_at: Time.current,
            reason: reason || "Manual pause by admin",
            warmup_stage: 0
          )
          exclusion.save!
        else
          # Update existing exclusion
          exclusion.update!(
            warmup_stage: 0,
            reason: reason || "Manual pause by admin",
            next_warmup_at: nil
          )
        end

        action = IPHealthAction.create!(
          ip_address: ip_address,
          action_type: IPHealthAction::PAUSE,
          destination_domain: destination_domain,
          reason: "Manual pause by #{user}: #{reason || 'No reason provided'}",
          previous_priority: ip_address.priority,
          new_priority: 0,
          user_id: nil # TODO: Look up user by email if needed
        )

        Rails.logger.info "[IP HEALTH] Manual pause for IP #{ip_address.ipv4} on domain #{destination_domain} by #{user}"

        # Send notification
        notifier = IPBlacklist::Notifier.new
        notifier.notify_ip_paused(ip_address, destination_domain, reason || "Manual pause by admin", action)
      end

      # Handle SMTP rejection with blacklist detection (hard bounce)
      #
      # @param ip_address [IPAddress] The IP address
      # @param destination_domain [String] The destination domain
      # @param parsed_response [Hash] Parsed SMTP response from SMTPResponseParser
      # @param smtp_code [String] The SMTP response code
      # @param smtp_message [String] The full SMTP error message
      #
      def handle_smtp_rejection(ip_address, destination_domain, parsed_response, smtp_code, smtp_message)
        return unless parsed_response[:blacklist_detected]

        # Create SMTP rejection event record
        rejection_event = SMTPRejectionEvent.create!(
          ip_address: ip_address,
          destination_domain: destination_domain,
          smtp_code: smtp_code,
          bounce_type: parsed_response[:bounce_type],
          smtp_message: smtp_message,
          parsed_details: parsed_response.to_json,
          occurred_at: Time.current
        )

        Rails.logger.warn "[SMTP REJECTION] IP #{ip_address.ipv4} rejected by #{destination_domain} - #{parsed_response[:description]}"

        # Create or update blacklist record
        blacklist_record = IPBlacklistRecord.find_or_initialize_by(
          ip_address: ip_address,
          destination_domain: destination_domain,
          blacklist_source: parsed_response[:blacklist_source] || "smtp_rejection"
        )

        if blacklist_record.new_record?
          blacklist_record.assign_attributes(
            detected_at: Time.current,
            detection_method: IPBlacklistRecord::SMTP_RESPONSE,
            smtp_response_code: smtp_code,
            smtp_response_message: smtp_message,
            smtp_rejection_event: rejection_event,
            status: IPBlacklistRecord::ACTIVE,
            details: {
              severity: parsed_response[:severity],
              description: parsed_response[:description],
              suggested_action: parsed_response[:suggested_action]
            }.to_json
          )
          blacklist_record.save!

          Rails.logger.warn "[SMTP REJECTION] Created blacklist record for IP #{ip_address.ipv4} - source: #{parsed_response[:blacklist_source]}"

          # Handle the blacklist using existing logic
          handle_blacklist_detected(blacklist_record)
        else
          # Update existing record with new SMTP rejection info
          blacklist_record.update!(
            last_checked_at: Time.current,
            check_count: blacklist_record.check_count + 1,
            smtp_response_code: smtp_code,
            smtp_response_message: smtp_message,
            smtp_rejection_event: rejection_event
          )

          Rails.logger.warn "[SMTP REJECTION] Updated existing blacklist record for IP #{ip_address.ipv4}"
        end
      end

      # Handle excessive soft bounces (threshold-based)
      #
      # @param ip_address [IPAddress] The IP address
      # @param destination_domain [String] The destination domain
      # @param reason [String] Optional reason
      #
      def handle_excessive_soft_bounces(ip_address, destination_domain, reason: nil)
        # Check recent soft bounce count from database
        recent_count = SMTPRejectionEvent.count_recent_soft_bounces(
          ip_address.id,
          destination_domain,
          60 # window_minutes
        )

        reason_text = reason || "Excessive soft bounces detected (#{recent_count} in last hour)"

        Rails.logger.warn "[SMTP SOFT BOUNCE] IP #{ip_address.ipv4} exceeded soft bounce threshold for #{destination_domain}"

        # Create or update exclusion for monitoring
        exclusion = IPDomainExclusion.find_or_initialize_by(
          ip_address: ip_address,
          destination_domain: destination_domain
        )

        if exclusion.new_record?
          exclusion.assign_attributes(
            excluded_at: Time.current,
            reason: reason_text,
            warmup_stage: 0
          )
          exclusion.save!
        else
          # Reset to stage 0 if it was warming up
          exclusion.update!(
            warmup_stage: 0,
            reason: reason_text,
            next_warmup_at: nil
          )
        end

        # Log the pause action
        action = IPHealthAction.create!(
          ip_address: ip_address,
          action_type: IPHealthAction::PAUSE,
          destination_domain: destination_domain,
          reason: reason_text,
          previous_priority: ip_address.priority,
          new_priority: 0,
          user_id: nil # automated
        )

        Rails.logger.warn "[IP HEALTH] Paused IP #{ip_address.ipv4} for domain #{destination_domain} due to excessive soft bounces"

        # Send notification
        notifier = IPBlacklist::Notifier.new
        notifier.notify_ip_paused(ip_address, destination_domain, reason_text, action)

        # Reset the soft bounce counter after taking action
        SoftBounceTracker.reset(ip_address_id: ip_address.id, destination_domain: destination_domain)
      end

      private

      # Check if we have other healthy IPs available and log rotation info
      def check_rotation_possibility(blacklist_record)
        ip_address = blacklist_record.ip_address
        destination_domain = blacklist_record.destination_domain
        pool = ip_address.ip_pool

        healthy_ips = pool.ip_addresses
                          .where.not(id: ip_address.id)
                          .healthy_for_domain(destination_domain)

        if healthy_ips.empty?
          Rails.logger.error "[CRITICAL] No healthy IPs available in pool #{pool.name} for domain #{destination_domain}"
          log_notification("no_healthy_ips_critical", "CRITICAL: No healthy IPs in pool #{pool.name} for domain #{destination_domain}")
        else
          Rails.logger.info "[IP HEALTH] Found #{healthy_ips.count} healthy IP(s) available for rotation in pool #{pool.name} for domain #{destination_domain}"
          log_notification("rotation_available", "#{healthy_ips.count} healthy IPs available - recommend rotating traffic away from #{ip_address.ipv4}")
        end
      end

      # Send notification (replaced with proper Notifier implementation)
      def log_notification(type, message)
        Rails.logger.info "[NOTIFICATION] Type: #{type}, Message: #{message}"
        # Legacy method - notifications now handled by IPBlacklist::Notifier
      end

    end

  end
end
