# frozen_string_literal: true

module MessageDequeuer
  class OutgoingMessageProcessor < Base

    def process
      catch_stops do
        check_domain
        check_rcpt_to
        resolve_mx_domain
        add_tag
        hold_if_credential_is_set_to_hold
        hold_if_recipient_on_suppression_list
        skip_if_mx_rate_limited
        skip_if_domain_throttled
        parse_content
        inspect_message
        fail_if_spam
        add_outgoing_headers
        check_send_limits
        increment_live_stats
        hold_if_server_development_mode
        send_message_to_sender
        handle_mx_rate_limit_response
        apply_domain_throttle_if_required
        add_recipient_to_suppression_list_on_too_many_hard_fails
        remove_recipient_from_suppression_list_on_success
        log_sender_result
        finish_processing
      end
    rescue StandardError => e
      handle_exception(e)
    end

    private

    def check_domain
      return if queued_message.message.domain

      log "message has no domain, hard failing"
      create_delivery "HardFail", details: "Message's domain no longer exist", ip_address_id: queued_message.ip_address_id
      remove_from_queue
      stop_processing
    end

    def check_rcpt_to
      return unless queued_message.message.rcpt_to.blank?

      log "message has no 'to' address, hard failing"
      create_delivery "HardFail", details: "Message doesn't have an RCPT to", ip_address_id: queued_message.ip_address_id
      remove_from_queue
      stop_processing
    end

    def add_tag
      return if queued_message.message.tag
      return unless tag = queued_message.message.headers["x-postal-tag"]

      log "added tag: #{tag.last}"
      queued_message.message.update(tag: tag.last)
    end

    def hold_if_credential_is_set_to_hold
      return if queued_message.manual?
      return if queued_message.message.credential.nil?
      return unless queued_message.message.credential.hold?

      log "credential wants us to hold messages, holding"
      create_delivery "Held", details: "Credential is configured to hold all messages authenticated by it.", ip_address_id: queued_message.ip_address_id
      remove_from_queue
      stop_processing
    end

    def hold_if_recipient_on_suppression_list
      return if queued_message.manual?
      return unless sl = queued_message.server.message_db.suppression_list.get(:recipient, queued_message.message.rcpt_to)

      log "recipient is on the suppression list, holding"
      create_delivery "Held", details: "Recipient (#{queued_message.message.rcpt_to}) is on the suppression list (reason: #{sl['reason']})", ip_address_id: queued_message.ip_address_id
      remove_from_queue
      stop_processing
    end

    def skip_if_domain_throttled
      return if queued_message.manual?

      domain = queued_message.message.recipient_domain
      return unless domain

      throttle = DomainThrottle.throttled?(queued_message.server, domain)
      return unless throttle

      # Requeue the message to retry after the throttle expires
      retry_seconds = throttle.remaining_seconds + 10
      queued_message.retry_later(retry_seconds)
      log "domain #{domain} is throttled, requeuing for later",
          throttled_until: throttle.throttled_until,
          retry_after: queued_message.retry_after,
          reason: throttle.reason
      stop_processing
    end

    def parse_content
      return unless queued_message.message.should_parse?

      log "parsing message content as it hasn't been parsed before"
      queued_message.message.parse_content
    end

    def inspect_message
      return if queued_message.message.inspected
      return unless queued_message.server.outbound_spam_threshold

      log "inspecting message"
      result = queued_message.message.inspect_message
      return unless queued_message.message.inspected

      # Check if email validation failed with Truemail
      if queued_message.server.truemail_enabled? && result.validation_failed
        log "email validation failed with Truemail, hard failing", validation_message: result.validation_message

        # Add recipient to suppression list for failed email validation
        queued_message.server.message_db.suppression_list.add(:recipient, queued_message.message.rcpt_to, reason: "Email address validation failed with Truemail: #{result.validation_message}")
        log "added recipient to suppression list", recipient: queued_message.message.rcpt_to, reason: "Truemail validation failed"

        create_delivery "HardFail",
                        details: "Email address validation failed: #{result.validation_message}",
                        ip_address_id: queued_message.ip_address_id
        remove_from_queue
        stop_processing
        return
      end

      if queued_message.message.spam_score >= queued_message.server.outbound_spam_threshold
        queued_message.message.update(spam: true)
      end

      log "message inspected successfully", spam: queued_message.message.spam?, spam_score: queued_message.message.spam_score, threat: queued_message.message.threat
    end

    def fail_if_spam
      return unless queued_message.message.spam

      log "message is spam (#{queued_message.message.spam_score}), hard failing", server_threshold: queued_message.server.outbound_spam_threshold
      create_delivery "HardFail",
                      details: "Message is likely spam. Threshold is #{queued_message.server.outbound_spam_threshold} and " \
                               "the message scored #{queued_message.message.spam_score}.",
                      ip_address_id: queued_message.ip_address_id
      remove_from_queue
      stop_processing
    end

    def add_outgoing_headers
      return if queued_message.message.has_outgoing_headers?

      queued_message.message.add_outgoing_headers
    end

    def check_send_limits
      if queued_message.server.send_limit_exceeded?
        # If we're over the limit, we're going to be holding this message
        log "server send limit has been exceeded, holding", send_limit: queued_message.server.send_limit
        queued_message.server.update_columns(send_limit_exceeded_at: Time.now, send_limit_approaching_at: nil)
        create_delivery "Held", details: "Message held because send limit (#{queued_message.server.send_limit}) has been reached.", ip_address_id: queued_message.ip_address_id
        remove_from_queue
        stop_processing
      elsif queued_message.server.send_limit_approaching?
        # If we're approaching the limit, just say we are but continue to process the message
        queued_message.server.update_columns(send_limit_approaching_at: Time.now, send_limit_exceeded_at: nil)
      else
        queued_message.server.update_columns(send_limit_approaching_at: nil, send_limit_exceeded_at: nil)
      end
    end

    def send_message_to_sender
      @result = @state.send_result
      return if @result

      sender = @state.sender_for(SMTPSender,
                                 queued_message.message.recipient_domain,
                                 queued_message.ip_address)

      @result = sender.send_message(queued_message.message)
      return unless @result.connect_error

      @state.send_result = @result
    end

    def apply_domain_throttle_if_required
      return unless @result
      return unless @result.domain_throttle_required

      domain = queued_message.message.recipient_domain
      return unless domain

      duration = @result.domain_throttle_duration || DomainThrottle::DEFAULT_THROTTLE_DURATION
      reason = @result.output.to_s.truncate(255)

      # Create or update the throttle for this domain
      throttle = DomainThrottle.apply(
        queued_message.server,
        domain,
        duration: duration,
        reason: reason
      )

      log "applied domain throttle",
          domain: domain,
          duration: duration,
          throttled_until: throttle.throttled_until,
          reason: reason

      # Update retry_after for all queued messages to the same domain on this server
      # This prevents other workers from attempting to send to the throttled domain
      throttle_all_queued_messages_for_domain(domain, throttle.throttled_until)
    end

    def throttle_all_queued_messages_for_domain(domain, throttled_until)
      retry_after = throttled_until + 10.seconds

      # Update all queued messages for this domain that don't already have a later retry_after
      updated_count = QueuedMessage.where(server_id: queued_message.server_id, domain: domain)
                                   .where("retry_after IS NULL OR retry_after < ?", retry_after)
                                   .where.not(id: queued_message.id)
                                   .update_all(retry_after: retry_after)

      return unless updated_count > 0

      log "throttled #{updated_count} additional queued messages for domain",
          domain: domain,
          retry_after: retry_after
    end

    def add_recipient_to_suppression_list_on_too_many_hard_fails
      return unless @result.type == "HardFail"

      recent_hard_fails = queued_message.server.message_db.select(:messages,
                                                                  where: {
                                                                    rcpt_to: queued_message.message.rcpt_to,
                                                                    status: "HardFail",
                                                                    timestamp: { greater_than: 24.hours.ago.to_f }
                                                                  },
                                                                  count: true)
      return if recent_hard_fails < 1

      added = queued_message.server.message_db.suppression_list.add(:recipient, queued_message.message.rcpt_to,
                                                                    reason: "too many hard fails")
      return unless added

      log "Added #{queued_message.message.rcpt_to} to suppression list because #{recent_hard_fails} hard fails in 24 hours"
      @additional_delivery_details = "Recipient added to suppression list (too many hard fails)"
    end

    def remove_recipient_from_suppression_list_on_success
      return unless @result.type == "Sent"

      removed = queued_message.server.message_db.suppression_list.remove(:recipient, queued_message.message.rcpt_to)
      return unless removed

      log "removed #{queued_message.message.rcpt_to} from suppression list"
      @additional_delivery_details = "Recipient removed from suppression list"
    end

    def finish_processing
      if @result.retry
        # Reallocate IP address on SoftFail to try with a different IP on next attempt
        if @result.type == "SoftFail"
          queued_message.reallocate_ip_address
          log "reallocated IP address for retry", new_ip_address_id: queued_message.ip_address_id
        end

        queued_message.retry_later(@result.retry.is_a?(Integer) ? @result.retry : nil)
        log "message requeued for trying later", retry_after: queued_message.retry_after
        stop_processing
      end

      log "message processing complete"
      remove_from_queue
    end

    def resolve_mx_domain
      queued_message.resolve_mx_domain!
      log "resolved MX domain", mx_domain: queued_message.mx_domain
    rescue StandardError => e
      log "failed to resolve MX domain", error: e.message
      # Don't block processing if resolution fails
    end

    def skip_if_mx_rate_limited
      return if queued_message.manual?
      return unless queued_message.mx_domain.present?

      rate_limit = queued_message.mx_rate_limit
      return unless rate_limit&.active?

      # Calculate retry time based on current delay
      retry_seconds = rate_limit.wait_seconds + 10
      queued_message.retry_later(retry_seconds)

      log "MX domain #{queued_message.mx_domain} is rate limited, requeuing",
          mx_domain: queued_message.mx_domain,
          current_delay: rate_limit.current_delay,
          error_count: rate_limit.error_count,
          retry_after: queued_message.retry_after

      # Log throttled event
      rate_limit.events.create!(
        server_id: queued_message.server_id,
        recipient_domain: queued_message.domain,
        event_type: "throttled",
        delay_before: rate_limit.current_delay,
        delay_after: rate_limit.current_delay,
        error_count: rate_limit.error_count,
        success_count: rate_limit.success_count,
        queued_message_id: queued_message.id
      )

      stop_processing
    end

    def handle_mx_rate_limit_response
      return unless @result
      return unless queued_message.mx_domain.present?

      # Analyze SMTP response
      if should_apply_mx_rate_limit?(@result)
        apply_mx_rate_limit
      elsif @result.type == "Sent"
        record_mx_success
      end
    end

    def should_apply_mx_rate_limit?(result)
      return false if result.type == "Sent"
      return false if result.output.blank?

      # Check pattern matching
      pattern = MXRateLimitPattern.match_message(result.output)
      return false unless pattern

      # Save matched pattern for logging
      @matched_pattern = pattern

      pattern.action == "rate_limit"
    end

    def apply_mx_rate_limit
      rate_limit = MXRateLimit.find_or_initialize_by(
        server: queued_message.server,
        mx_domain: queued_message.mx_domain
      )

      rate_limit.record_error(
        smtp_response: @result.output,
        pattern: @matched_pattern&.name,
        queued_message: queued_message
      )

      log "applied MX rate limit",
          mx_domain: queued_message.mx_domain,
          error_count: rate_limit.error_count,
          current_delay: rate_limit.current_delay,
          matched_pattern: @matched_pattern&.name

      # Requeue pending messages for same MX
      requeue_messages_for_mx(queued_message.mx_domain, rate_limit.current_delay)
    end

    def record_mx_success
      rate_limit = MXRateLimit.find_by(
        server: queued_message.server,
        mx_domain: queued_message.mx_domain
      )

      return unless rate_limit

      rate_limit.record_success(queued_message: queued_message)

      return unless rate_limit.current_delay == 0

      log "MX rate limit cleared",
          mx_domain: queued_message.mx_domain,
          success_count: rate_limit.success_count
    end

    def requeue_messages_for_mx(mx_domain, delay_seconds)
      retry_after = Time.current + delay_seconds.seconds + 10.seconds

      # Update all queued messages for this MX domain
      updated_count = QueuedMessage
                      .where(server_id: queued_message.server_id, mx_domain: mx_domain)
                      .where("retry_after IS NULL OR retry_after < ?", retry_after)
                      .where.not(id: queued_message.id)
                      .update_all(retry_after: retry_after)

      return unless updated_count > 0

      log "requeued messages for MX domain",
          mx_domain: mx_domain,
          count: updated_count,
          retry_after: retry_after
    end

  end
end
