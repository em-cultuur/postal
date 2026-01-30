# frozen_string_literal: true

class SMTPSender < BaseSender

  attr_reader :endpoints

  # @param domain [String] the domain to send mesages to
  # @param source_ip_address [IPAddress] the IP address to send messages from
  # @param log_id [String] an ID to use when logging requests
  def initialize(domain, source_ip_address = nil, servers: nil, log_id: nil, rcpt_to: nil)
    super()
    @domain = domain
    @source_ip_address = source_ip_address
    @rcpt_to = rcpt_to

    # An array of servers to forcefully send the message to
    @servers = servers
    # Stores all connection errors which we have seen during this send sesssion.
    @connection_errors = []
    # Stores all endpoints that we have attempted to deliver mail to
    @endpoints = []
    # Generate a log ID which can be used if none has been provided to trace
    # this SMTP session.
    @log_id = log_id || SecureRandom.alphanumeric(8).upcase
  end

  def start
    servers = @servers || self.class.smtp_relays || resolve_mx_records_for_domain || []

    servers.each do |server|
      server.endpoints.each do |endpoint|
        result = connect_to_endpoint(endpoint)
        return endpoint if result
      end
    end

    false
  end

  def send_message(message)
    # If we don't have a current endpoint than we should raise an error.
    if @current_endpoint.nil?
      return create_result("SoftFail") do |r|
        r.retry = true
        r.details = "No SMTP servers were available for #{@domain}."
        if @endpoints.empty?
          r.details += " No hosts to try."
        else
          hostnames = @endpoints.map { |e| e.server.hostname }.uniq
          r.details += " Tried #{hostnames.to_sentence}."
        end
        r.output = @connection_errors.join(", ")
        r.connect_error = true
      end
    end

    mail_from = determine_mail_from_for_message(message)
    raw_message = message.raw_message

    # Append the Resent-Sender header to the mesage to include the
    # MAIL FROM if the installation is configured to use that?
    if Postal::Config.postal.use_resent_sender_header?
      raw_message = "Resent-Sender: #{mail_from}\r\n" + raw_message
    end

    rcpt_to = determine_rcpt_to_for_message(message)
    logger.info "Sending message #{message.server.id}::#{message.id} to #{rcpt_to}"
    send_message_to_smtp_client(raw_message, mail_from, rcpt_to)
  end

  def finish
    @endpoints.each(&:finish_smtp_session)
  end

  private

  # Take a message and attempt to send it to the SMTP server that we are
  # currently connected to. If there is a connection error, we will just
  # reset the client and retry again once.
  #
  # @param raw_message [String] the raw message to send
  # @param mail_from [String] the MAIL FROM address to use
  # @param rcpt_to [String] the RCPT TO address to use
  # @param retry_on_connection_error [Boolean] if true, we will retry the connection if there is an error
  #
  # @return [SendResult]
  def send_message_to_smtp_client(raw_message, mail_from, rcpt_to, retry_on_connection_error: true)
    start_time = Time.now
    smtp_result = @current_endpoint.send_message(raw_message, mail_from, [rcpt_to])
    logger.info "Accepted by #{@current_endpoint} for #{rcpt_to}"
    create_result("Sent", start_time) do |r|
      r.details = "Message for #{rcpt_to} accepted by #{@current_endpoint}"
      r.details += " (from #{@current_endpoint.smtp_client.source_address})" if @current_endpoint.smtp_client.source_address
      r.output = smtp_result.string
    end
  rescue Net::SMTPServerBusy, Net::SMTPAuthenticationError, Net::SMTPSyntaxError, Net::SMTPUnknownError, Net::ReadTimeout => e
    logger.error "#{e.class}: #{e.message}"
    @current_endpoint.reset_smtp_session

    # Parse SMTP response for blacklist detection (soft bounce)
    logger.info "About to call handle_smtp_error_response (soft bounce)"
    handle_smtp_error_response(e, soft_bounce: true)
    logger.info "Finished handle_smtp_error_response (soft bounce)"

    create_result("SoftFail", start_time) do |r|
      r.details = "Temporary SMTP delivery error when sending to #{@current_endpoint}"
      r.output = e.message
      if e.message =~ /(\d+) seconds/
        r.retry = ::Regexp.last_match(1).to_i + 10
      elsif e.message =~ /(\d+) minutes/
        r.retry = (::Regexp.last_match(1).to_i * 60) + 10
      else
        r.retry = true
      end

      # Check for rate limiting responses (451 too many messages, slow down, etc.)
      if requires_domain_throttle?(e.message)
        r.domain_throttle_required = true
        r.domain_throttle_duration = extract_throttle_duration(e.message)
        logger.info "Domain throttling required: #{r.domain_throttle_duration} seconds"
      end
    end
  rescue Net::SMTPFatalError => e
    logger.error "#{e.class}: #{e.message}"
    @current_endpoint.reset_smtp_session

    # Parse SMTP response for blacklist detection (hard bounce)
    logger.info "About to call handle_smtp_error_response (hard bounce)"
    blacklist_detected = handle_smtp_error_response(e, soft_bounce: false)
    logger.info "Finished handle_smtp_error_response (hard bounce) - blacklist_detected: #{blacklist_detected}"

    # If blacklist detected, convert to SoftFail to allow retry with different IP
    if blacklist_detected
      logger.warn "Blacklist detected - converting HardFail to SoftFail for retry with different IP"
      create_result("SoftFail", start_time) do |r|
        r.details = "IP blacklist detected when sending to #{@current_endpoint} - will retry with different IP"
        r.output = e.message
        r.retry = true
      end
    else
      create_result("HardFail", start_time) do |r|
        r.details = "Permanent SMTP delivery error when sending to #{@current_endpoint}"
        r.output = e.message
      end
    end
  rescue StandardError => e
    logger.error "#{e.class}: #{e.message}"
    @current_endpoint.reset_smtp_session

    if defined?(Sentry)
      # Sentry.capture_exception(e, extra: { log_id: @log_id, server_id: message.server.id, message_id: message.id })
    end

    create_result("SoftFail", start_time) do |r|
      r.type = "SoftFail"
      r.retry = true
      r.details = "An error occurred while sending the message to #{@current_endpoint}"
      r.output = e.message
    end
  end

  # Return the MAIL FROM which should be used for the given message
  #
  # @param message [MessageDB::Message]
  # @return [String]
  def determine_mail_from_for_message(message)
    return "" if message.bounce

    # If the domain has a valid custom return path configured, return
    # that.
    if message.domain.return_path_status == "OK"
      return "#{message.server.token}@#{message.domain.return_path_domain}"
    end

    "#{message.server.token}@#{Postal::Config.dns.return_path_domain}"
  end

  # Return the RCPT TO to use for the given message in this sending session
  #
  # @param message [MessageDB::Message]
  # @return [String]
  def determine_rcpt_to_for_message(message)
    return @rcpt_to if @rcpt_to

    message.rcpt_to
  end

  # Return an array of server hostnames which should receive this message
  #
  # @return [Array<String>]
  def resolve_mx_records_for_domain
    hostnames = DNSResolver.local.mx(@domain, raise_timeout_errors: true).map(&:last)
    return [SMTPClient::Server.new(@domain)] if hostnames.empty?

    hostnames.map { |hostname| SMTPClient::Server.new(hostname) }
  end

  # Attempt to begin an SMTP sesssion for the given endpoint. If successful, this endpoint
  # becomes the current endpoints for the SMTP sender.
  #
  # Returns true if the session was established.
  # Returns false if the session could not be established.
  #
  # @param endpoint [SMTPClient::Endpoint]
  # @return [Boolean]
  def connect_to_endpoint(endpoint, allow_ssl: true)
    if (@source_ip_address && @source_ip_address.ipv6.blank? && endpoint.ipv6?) || Postal::Config.smtp.disable_ipv6
      # Don't try to use IPv6 if the IP address we're sending from doesn't support it or if it's disabled in the config.
      return false
    end

    # Add this endpoint to the list of endpoints that we have attempted to connect to
    @endpoints << endpoint unless @endpoints.include?(endpoint)

    logger.info "SMTP connect to: #{endpoint}"
    logger.info "SMTP HELO/EHLO: #{@source_ip_address ? @source_ip_address.hostname : endpoint.class.default_helo_hostname}"

    endpoint.start_smtp_session(allow_ssl: allow_ssl, source_ip_address: @source_ip_address)
    logger.info "Connected to #{endpoint}"
    @current_endpoint = endpoint

    true
  rescue StandardError => e
    # Disconnect the SMTP client if we get any errors to avoid leaving
    # a connection around.
    endpoint.finish_smtp_session

    # If we get an SSL error, we can retry a connection without
    # ssl.
    if e.is_a?(OpenSSL::SSL::SSLError) && endpoint.server.ssl_mode == "Auto"
      logger.error "SSL error (#{e.message}), retrying without SSL"
      return connect_to_endpoint(endpoint, allow_ssl: false)
    end

    # Otherwise, just log the connection error and return false
    logger.error "Cannot connect to #{endpoint} (#{e.class}: #{e.message}) from #{@source_ip_address.nil? ? 'default IP' : @source_ip_address.ipv4}"
    @connection_errors << e.message unless @connection_errors.include?(e.message)

    false
  end

  # Create a new result object
  #
  # @param type [String] the type of result
  # @param start_time [Time] the time the operation started
  # @yieldparam [SendResult] the result object
  # @yieldreturn [void]
  #
  # @return [SendResult]
  def create_result(type, start_time = nil)
    result = SendResult.new
    result.type = type
    result.log_id = @log_id
    result.secure = @current_endpoint&.smtp_client&.secure_socket? ? true : false
    yield result if block_given?
    if start_time
      result.time = (Time.now - start_time).to_f.round(2)
    end
    result
  end

  def logger
    @logger ||= Postal.logger.create_tagged_logger(log_id: @log_id)
  end

  # Handle SMTP error responses and check for blacklist indicators
  #
  # @param exception [Exception] The SMTP exception
  # @param soft_bounce [Boolean] Whether this is a soft bounce
  # @return [Boolean] True if blacklist was detected, false otherwise
  #
  def handle_smtp_error_response(exception, soft_bounce:)
    unless smtp_response_analysis_enabled?
      return false
    end

    # Try to get source IP address
    source_ip = @source_ip_address

    # If no IP address is set, try to extract it from the SMTP error message
    if source_ip.nil?
      extracted_ip = extract_ip_from_smtp_message(exception.message)
      if extracted_ip
        source_ip = find_ip_address_by_ip(extracted_ip)
        unless source_ip
          logger.debug "[SMTP BLACKLIST] Extracted IP #{extracted_ip} not found in database"
          return false
        end
      else
        logger.debug "[SMTP BLACKLIST] Could not extract IP from error message"
        return false
      end
    end

    # Extract SMTP code from exception message
    smtp_code = extract_smtp_code(exception.message)
    unless smtp_code
      return false
    end

    # Parse the SMTP response
    parsed = IPBlacklist::SMTPResponseParser.parse(exception.message, smtp_code)

    # Handle based on blacklist detection and bounce type
    if parsed[:blacklist_detected]
      handle_blacklist_detected_in_smtp(parsed, smtp_code, exception.message, soft_bounce, source_ip)
      return true
    end

    false
  rescue StandardError => e
    # Don't let SMTP analysis errors break the main flow
    logger.error "[SMTP ANALYSIS ERROR] #{e.class}: #{e.message}"
    logger.error e.backtrace.join("\n")
    false
  end

  # Handle blacklist detection from SMTP response
  #
  # @param parsed [Hash] Parsed SMTP response
  # @param smtp_code [String] The SMTP code
  # @param smtp_message [String] The full SMTP error message
  # @param soft_bounce [Boolean] Whether this is a soft bounce
  # @param source_ip [IPAddress] The source IP address (either from @source_ip_address or extracted)
  #
  def handle_blacklist_detected_in_smtp(parsed, smtp_code, smtp_message, soft_bounce, source_ip)
    logger.warn "[SMTP BLACKLIST] Detected on IP #{source_ip.ipv4} for #{@domain}: #{parsed[:description]} (#{parsed[:severity]} severity)"

    if soft_bounce
      # Track soft bounces and check threshold
      tracker = IPBlacklist::SoftBounceTracker.new(
        ip_address_id: source_ip.id,
        destination_domain: @domain,
        threshold: smtp_soft_bounce_threshold,
        window_minutes: smtp_soft_bounce_window
      )

      if tracker.record_and_check_threshold
        logger.warn "[SMTP BLACKLIST] Soft bounce threshold exceeded (#{tracker.current_count}/#{tracker.threshold}) - pausing IP #{source_ip.ipv4} for #{@domain}"
        IPBlacklist::IPHealthManager.handle_excessive_soft_bounces(
          source_ip,
          @domain,
          reason: "Soft bounce threshold exceeded: #{parsed[:description]}"
        )
      end
    elsif parsed[:severity] == "high"
      # Hard bounce - take immediate action if severity is high
      logger.warn "[SMTP BLACKLIST] High severity hard bounce - pausing IP #{source_ip.ipv4} for #{@domain}"
      IPBlacklist::IPHealthManager.handle_smtp_rejection(
        source_ip,
        @domain,
        parsed,
        smtp_code,
        smtp_message
      )
    end
  end

  # Extract SMTP code from error message
  #
  # @param message [String] The error message
  # @return [String, nil] The SMTP code (e.g., "550", "421")
  #
  def extract_smtp_code(message)
    # SMTP codes are typically 3 digits at the start of the message
    match = message.match(/^(\d{3})/)
    match ? match[1] : nil
  end

  # Extract IP address from SMTP error message
  #
  # @param message [String] The SMTP error message
  # @return [String, nil] The extracted IP address (IPv4 or IPv6)
  #
  def extract_ip_from_smtp_message(message)
    return nil if message.blank?

    # Pattern 1: IP in square brackets [1.2.3.4] or [2001:db8::1]
    # Common in Microsoft/Outlook errors: "messages from [209.227.233.135] weren't sent"
    if match = message.match(/\[([0-9a-fA-F:.]+)\]/)
      ip = match[1]
      return ip if valid_ip_format?(ip)
    end

    # Pattern 2: IP after "from" keyword
    # Example: "from 1.2.3.4" or "from IP 1.2.3.4"
    if match = message.match(/from\s+(?:IP\s+)?([0-9a-fA-F:.]+)/i)
      ip = match[1]
      return ip if valid_ip_format?(ip)
    end

    # Pattern 3: IP after "Client host" or "host"
    # Example: "Client host 1.2.3.4 rejected"
    if match = message.match(/(?:Client\s+)?host\s+([0-9a-fA-F:.]+)/i)
      ip = match[1]
      return ip if valid_ip_format?(ip)
    end

    nil
  end

  # Check if a string looks like a valid IP address (IPv4 or IPv6)
  #
  # @param ip [String] The IP string to validate
  # @return [Boolean] True if it looks like a valid IP
  #
  def valid_ip_format?(ip)
    return false if ip.blank?

    # IPv4: 4 octets separated by dots
    return true if ip.match?(/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/)

    # IPv6: contains colons and hex characters
    return true if ip.match?(/^[0-9a-fA-F:]+$/) && ip.include?(":")

    false
  end

  # Find IPAddress model by IP string (IPv4 or IPv6)
  #
  # @param ip_string [String] The IP address as string
  # @return [IPAddress, nil] The IPAddress model if found
  #
  def find_ip_address_by_ip(ip_string)
    return nil if ip_string.blank?

    # Try to find by IPv4 or IPv6
    if ip_string.include?(":")
      # IPv6
      IPAddress.find_by(ipv6: ip_string)
    else
      # IPv4
      IPAddress.find_by(ipv4: ip_string)
    end
  end

  # Check if SMTP response analysis is enabled
  #
  # @return [Boolean]
  #
  def smtp_response_analysis_enabled?
    # Check configuration - default to true if not specified
    return true unless Postal::Config.postal.respond_to?(:ip_reputation)

    config = Postal::Config.postal.ip_reputation
    return true unless config.respond_to?(:smtp_response_analysis)

    config.smtp_response_analysis.enabled != false
  rescue StandardError
    true # Default to enabled if config access fails
  end

  # Get soft bounce threshold from config
  #
  # @return [Integer]
  #
  def smtp_soft_bounce_threshold
    return IPBlacklist::SoftBounceTracker::DEFAULT_THRESHOLD unless Postal::Config.postal.respond_to?(:ip_reputation)

    config = Postal::Config.postal.ip_reputation&.smtp_response_analysis
    config&.soft_bounce_threshold || IPBlacklist::SoftBounceTracker::DEFAULT_THRESHOLD
  rescue StandardError
    IPBlacklist::SoftBounceTracker::DEFAULT_THRESHOLD
  end

  # Get soft bounce window from config
  #
  # @return [Integer]
  #
  def smtp_soft_bounce_window
    return IPBlacklist::SoftBounceTracker::DEFAULT_WINDOW_MINUTES unless Postal::Config.postal.respond_to?(:ip_reputation)

    config = Postal::Config.postal.ip_reputation&.smtp_response_analysis
    config&.soft_bounce_window_minutes || IPBlacklist::SoftBounceTracker::DEFAULT_WINDOW_MINUTES
  rescue StandardError
    IPBlacklist::SoftBounceTracker::DEFAULT_WINDOW_MINUTES
  end

  # Check if the error message indicates that domain-level throttling is required
  #
  # @param message [String] the SMTP error message
  # @return [Boolean]
  def requires_domain_throttle?(message)
    return false if message.blank?

    # Exclude messages that contain an IP address (these are typically IP-specific blocks, not domain throttling)
    ip_pattern = /\b(?:\d{1,3}\.){3}\d{1,3}\b/
    return false if message.match?(ip_pattern)

    # Match common patterns for rate limiting responses
    # 451 is the standard code for "try again later"
    throttle_patterns = [
      /\b451\b.*\b(too many|rate limit|slow down|try again later|temporarily deferred)/i,
      /\b(too many messages|too many connections|rate limit|sending rate|slow down)\b/i,
      /\b(temporarily rejected|temporarily deferred|try again later)\b.*\b(rate|limit|too many)/i,
    ]

    throttle_patterns.any? { |pattern| message.match?(pattern) }
  end

  # Extract throttle duration from SMTP error message
  #
  # @param message [String] the SMTP error message
  # @return [Integer] duration in seconds (default: 300 = 5 minutes)
  def extract_throttle_duration(message)
    default_duration = DomainThrottle::DEFAULT_THROTTLE_DURATION

    return default_duration if message.blank?

    # Try to extract a specific time from the message
    if message =~ /(\d+)\s*seconds?/i
      return [::Regexp.last_match(1).to_i + 10, default_duration].max
    elsif message =~ /(\d+)\s*minutes?/i
      return [(::Regexp.last_match(1).to_i * 60) + 10, default_duration].max
    elsif message =~ /(\d+)\s*hours?/i
      # Cap at max throttle duration for very long delays
      return [::Regexp.last_match(1).to_i * 3600, DomainThrottle::MAX_THROTTLE_DURATION].min
    end

    default_duration
  end

  class << self

    # Return an array of SMTP relays as configured. Returns nil
    # if no SMTP relays are configured.
    #
    def smtp_relays
      return @smtp_relays if instance_variable_defined?("@smtp_relays")

      relays = Postal::Config.postal.smtp_relays
      return nil if relays.nil?

      relays = relays.filter_map do |relay|
        next unless relay.host.present?

        SMTPClient::Server.new(relay.host, port: relay.port, ssl_mode: relay.ssl_mode)
      end

      @smtp_relays = relays.empty? ? nil : relays
    end

  end

end
