# frozen_string_literal: true

module IPMetrics
  # Aggregates delivery statistics from MessageDB into IPReputationMetric records
  # Queries the deliveries table per server and groups by IP address and destination domain
  class Aggregator

    class << self

      # Aggregate metrics for a specific time period
      # @param period [String] One of: 'hourly', 'daily', 'weekly', 'monthly'
      # @param period_date [Date,Time] The date/time to aggregate for
      # @param server_ids [Array<Integer>] Optional: specific servers to aggregate (default: all)
      def aggregate(period:, period_date:, server_ids: nil)
        validate_period!(period)
        period_date = normalize_period_date(period_date, period)

        servers = server_ids ? Server.where(id: server_ids) : Server.all
        total_records = 0

        servers.each do |server|
          records_created = aggregate_for_server(server, period, period_date)
          total_records += records_created
        rescue StandardError => e
          Rails.logger.error "[IPMetrics::Aggregator] Failed to aggregate for server #{server.id}: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
        end

        Rails.logger.info "[IPMetrics::Aggregator] Aggregated #{total_records} metric records for period #{period} on #{period_date}"
        total_records
      end

      # Aggregate metrics for a specific server
      def aggregate_for_server(server, period, period_date)
        return 0 unless server.message_db

        time_range = period_time_range(period, period_date)
        deliveries = fetch_deliveries(server.message_db, time_range)

        return 0 if deliveries.empty?

        # Group deliveries by IP and destination domain
        grouped = group_deliveries(deliveries)

        # Create or update metric records
        records_created = 0
        grouped.each do |key, stats|
          next unless key[:ip_address_id] # Skip if no IP assigned

          metric = find_or_initialize_metric(
            ip_address_id: key[:ip_address_id],
            destination_domain: key[:destination_domain],
            sender_domain: key[:sender_domain],
            period: period,
            period_date: period_date
          )

          update_metric_with_stats(metric, stats)

          if metric.save
            records_created += 1
          else
            Rails.logger.warn "[IPMetrics::Aggregator] Failed to save metric: #{metric.errors.full_messages.join(', ')}"
          end
        end

        records_created
      end

      # Aggregate recent metrics (useful for scheduled tasks)
      # @param periods [Array<String>] Periods to aggregate (default: hourly and daily)
      def aggregate_recent(periods: [IPReputationMetric::HOURLY, IPReputationMetric::DAILY])
        periods.each do |period|
          case period
          when IPReputationMetric::HOURLY
            # Aggregate last 2 hours (current + previous for safety)
            2.times do |i|
              aggregate(period: period, period_date: i.hours.ago)
            end
          when IPReputationMetric::DAILY
            # Aggregate today and yesterday
            aggregate(period: period, period_date: Date.current)
            aggregate(period: period, period_date: Date.yesterday)
          when IPReputationMetric::WEEKLY
            # Aggregate current week
            aggregate(period: period, period_date: Date.current.beginning_of_week)
          when IPReputationMetric::MONTHLY
            # Aggregate current month
            aggregate(period: period, period_date: Date.current.beginning_of_month)
          end
        end
      end

      private

      def validate_period!(period)
        return if IPReputationMetric::PERIODS.include?(period)

        raise ArgumentError, "Invalid period '#{period}'. Must be one of: #{IPReputationMetric::PERIODS.join(', ')}"
      end

      def normalize_period_date(date_or_time, period)
        time = date_or_time.is_a?(Time) ? date_or_time : date_or_time.to_time

        case period
        when IPReputationMetric::HOURLY
          time.beginning_of_hour.to_date # Store as date, but represents hour boundary
        when IPReputationMetric::DAILY
          time.to_date
        when IPReputationMetric::WEEKLY
          time.to_date.beginning_of_week
        when IPReputationMetric::MONTHLY
          time.to_date.beginning_of_month
        end
      end

      def period_time_range(period, period_date)
        start_time = period_date.to_time

        case period
        when IPReputationMetric::HOURLY
          end_time = start_time + 1.hour
        when IPReputationMetric::DAILY
          end_time = start_time + 1.day
        when IPReputationMetric::WEEKLY
          end_time = start_time + 1.week
        when IPReputationMetric::MONTHLY
          end_time = start_time + 1.month
        end

        [start_time.to_f, end_time.to_f]
      end

      # Fetch deliveries from MessageDB within time range
      def fetch_deliveries(message_db, time_range)
        start_time, end_time = time_range

        # Validate input types to prevent injection
        unless start_time.is_a?(Numeric) && end_time.is_a?(Numeric)
          raise ArgumentError, "Invalid time range: must be numeric timestamps"
        end

        # Query deliveries table directly with parameterized query
        # We need: message_id (to join to messages for IP and domain info), status, timestamp
        sql = <<-SQL
          SELECT#{' '}
            d.message_id,
            d.status,
            d.timestamp
          FROM deliveries d
          WHERE d.timestamp >= ? AND d.timestamp < ?
        SQL

        # Use parameterized query to prevent SQL injection
        sanitized_sql = ActiveRecord::Base.sanitize_sql_array([sql, start_time, end_time])
        deliveries = message_db.query(sanitized_sql)

        # Now we need to enrich these with message data (ip_address_id, rcpt_to domain)
        # Get unique message_ids and fetch message details in batch
        message_ids = deliveries.map { |d| d["message_id"] }.compact.uniq
        return [] if message_ids.empty?

        # Validate all message IDs are integers to prevent injection
        message_ids = message_ids.map(&:to_i).select { |id| id > 0 }
        return [] if message_ids.empty?

        # Create parameterized query with placeholders for IN clause
        placeholders = (["?"] * message_ids.size).join(",")
        messages_sql = <<-SQL
          SELECT#{' '}
            m.id,
            m.rcpt_to,
            m.mail_from
          FROM messages m
          WHERE m.id IN (#{placeholders})
        SQL

        # Use parameterized query to prevent SQL injection
        sanitized_messages_sql = ActiveRecord::Base.sanitize_sql_array([messages_sql, *message_ids])
        messages = message_db.query(sanitized_messages_sql)
        messages_by_id = messages.index_by { |m| m["id"] }

        # Get queued_messages to find IP associations
        # Note: queued_messages might be deleted after successful delivery
        # We'll do our best to find IP associations
        queued_messages_map = fetch_ip_associations_for_messages(message_ids, message_db.server_id)

        # Enrich deliveries with message data
        deliveries.map do |delivery|
          message = messages_by_id[delivery["message_id"]]
          next unless message

          {
            status: delivery["status"],
            timestamp: delivery["timestamp"],
            ip_address_id: queued_messages_map[delivery["message_id"]],
            destination_domain: extract_domain(message["rcpt_to"]),
            sender_domain: extract_domain(message["mail_from"])
          }
        end.compact
      end

      # Fetch IP address associations for messages from queued_messages table
      # Note: This may not find all associations if messages were already removed from queue
      def fetch_ip_associations_for_messages(message_ids, server_id)
        return {} if message_ids.empty?

        # Query main DB for queued_messages
        queued = QueuedMessage.where(
          message_id: message_ids,
          server_id: server_id
        ).pluck(:message_id, :ip_address_id)

        queued.to_h
      end

      def extract_domain(email)
        return nil if email.blank?

        email.split("@").last&.downcase
      end

      # Group deliveries by IP, destination domain, sender domain
      # Returns hash with keys {:ip_address_id, :destination_domain, :sender_domain}
      # and values containing aggregated stats
      def group_deliveries(deliveries)
        grouped = Hash.new do |h, key|
          h[key] = {
            sent_count: 0,
            delivered_count: 0,
            bounced_count: 0,
            soft_fail_count: 0,
            hard_fail_count: 0,
            spam_complaint_count: 0 # NOTE: spam complaints are tracked separately, not in deliveries
          }
        end

        deliveries.each do |delivery|
          key = {
            ip_address_id: delivery[:ip_address_id],
            destination_domain: delivery[:destination_domain],
            sender_domain: delivery[:sender_domain]
          }

          stats = grouped[key]
          stats[:sent_count] += 1

          case delivery[:status]
          when "Sent"
            stats[:delivered_count] += 1
          when "SoftFail"
            stats[:soft_fail_count] += 1
            stats[:bounced_count] += 1
          when "HardFail", "Bounced"
            stats[:hard_fail_count] += 1
            stats[:bounced_count] += 1
          when "Held"
            # Held messages don't count as sent yet
            stats[:sent_count] -= 1
          when "HoldCancelled"
            # Cancelled holds don't count
            stats[:sent_count] -= 1
          end
        end

        grouped
      end

      def find_or_initialize_metric(ip_address_id:, destination_domain:, sender_domain:, period:, period_date:)
        IPReputationMetric.find_or_initialize_by(
          ip_address_id: ip_address_id,
          destination_domain: destination_domain,
          sender_domain: sender_domain,
          period: period,
          period_date: period_date
        )
      end

      def update_metric_with_stats(metric, stats)
        # Update counts (these should be cumulative if metric already exists)
        metric.sent_count = stats[:sent_count]
        metric.delivered_count = stats[:delivered_count]
        metric.bounced_count = stats[:bounced_count]
        metric.soft_fail_count = stats[:soft_fail_count]
        metric.hard_fail_count = stats[:hard_fail_count]
        metric.spam_complaint_count = stats[:spam_complaint_count]

        # Calculate rates using the model's method
        metric.calculate_rates

        # Calculate reputation score using the model's method
        metric.calculate_reputation_score
      end

    end

  end
end
