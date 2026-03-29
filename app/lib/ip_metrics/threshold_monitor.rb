# frozen_string_literal: true

module IPMetrics
  # Monitors IP reputation metrics against thresholds and triggers automated actions
  # Provides flexible threshold configuration and action escalation
  class ThresholdMonitor

    # Default threshold configuration
    DEFAULT_THRESHOLDS = {
      bounce_rate: {
        warning: 500,    # 5%
        critical: 1000   # 10%
      },
      spam_rate: {
        warning: 100,    # 1%
        critical: 300    # 3%
      },
      delivery_rate: {
        warning: 9000,   # 90%
        critical: 8500   # 85%
      },
      reputation_score: {
        warning: 60,
        critical: 40
      }
    }.freeze

    # Minimum volume before thresholds are enforced
    DEFAULT_MINIMUM_VOLUME = 10

    attr_reader :thresholds, :minimum_volume, :logger

    def initialize(thresholds: nil, minimum_volume: nil, logger: nil)
      @thresholds = thresholds || load_config_thresholds || DEFAULT_THRESHOLDS
      @minimum_volume = minimum_volume || load_config_minimum_volume || DEFAULT_MINIMUM_VOLUME
      @logger = logger || Rails.logger
    end

    # Monitor a specific IP address across all domains
    # @param ip_address [IPAddress] The IP to monitor
    # @param period [String] Period to check (hourly, daily)
    # @param lookback_hours [Integer] How far back to look
    # @return [Array<Hash>] Violations found
    def monitor_ip(ip_address, period: IPReputationMetric::HOURLY, lookback_hours: 24)
      since = lookback_hours.hours.ago

      metrics = IPReputationMetric
                .where(ip_address: ip_address)
                .for_period(period)
                .where("period_date >= ?", since)
                .internal_metrics

      violations = []

      metrics.each do |metric|
        next if metric.sent_count < minimum_volume

        violation = check_thresholds(metric)
        violations << violation if violation
      end

      violations
    end

    # Monitor all IPs and return violations
    # @param period [String] Period to check
    # @param lookback_hours [Integer] How far back to look
    # @return [Hash] Violations grouped by severity
    def monitor_all(period: IPReputationMetric::HOURLY, lookback_hours: 24)
      since = lookback_hours.hours.ago

      metrics = IPReputationMetric
                .for_period(period)
                .where("period_date >= ?", since)
                .internal_metrics
                .includes(:ip_address)
                .where("sent_count >= ?", minimum_volume)

      violations = { critical: [], warning: [] }

      metrics.each do |metric|
        violation = check_thresholds(metric)
        next unless violation

        violations[violation[:severity]] << violation
      end

      violations
    end

    # Check if a metric violates any thresholds
    # @param metric [IPReputationMetric] The metric to check
    # @return [Hash, nil] Violation details or nil if no violation
    def check_thresholds(metric)
      return nil if metric.sent_count < minimum_volume

      violations_found = []

      # Check bounce rate
      if metric.bounce_rate >= thresholds[:bounce_rate][:critical]
        violations_found << {
          metric: :bounce_rate,
          threshold_type: :critical,
          threshold_value: thresholds[:bounce_rate][:critical],
          actual_value: metric.bounce_rate,
          percentage: metric.bounce_rate_percentage
        }
      elsif metric.bounce_rate >= thresholds[:bounce_rate][:warning]
        violations_found << {
          metric: :bounce_rate,
          threshold_type: :warning,
          threshold_value: thresholds[:bounce_rate][:warning],
          actual_value: metric.bounce_rate,
          percentage: metric.bounce_rate_percentage
        }
      end

      # Check spam rate
      if metric.spam_rate >= thresholds[:spam_rate][:critical]
        violations_found << {
          metric: :spam_rate,
          threshold_type: :critical,
          threshold_value: thresholds[:spam_rate][:critical],
          actual_value: metric.spam_rate,
          percentage: metric.spam_rate_percentage
        }
      elsif metric.spam_rate >= thresholds[:spam_rate][:warning]
        violations_found << {
          metric: :spam_rate,
          threshold_type: :warning,
          threshold_value: thresholds[:spam_rate][:warning],
          actual_value: metric.spam_rate,
          percentage: metric.spam_rate_percentage
        }
      end

      # Check delivery rate (lower is worse, so comparison is reversed)
      if metric.delivery_rate <= thresholds[:delivery_rate][:critical]
        violations_found << {
          metric: :delivery_rate,
          threshold_type: :critical,
          threshold_value: thresholds[:delivery_rate][:critical],
          actual_value: metric.delivery_rate,
          percentage: metric.delivery_rate_percentage
        }
      elsif metric.delivery_rate <= thresholds[:delivery_rate][:warning]
        violations_found << {
          metric: :delivery_rate,
          threshold_type: :warning,
          threshold_value: thresholds[:delivery_rate][:warning],
          actual_value: metric.delivery_rate,
          percentage: metric.delivery_rate_percentage
        }
      end

      # Check reputation score (lower is worse, so comparison is reversed)
      if metric.reputation_score <= thresholds[:reputation_score][:critical]
        violations_found << {
          metric: :reputation_score,
          threshold_type: :critical,
          threshold_value: thresholds[:reputation_score][:critical],
          actual_value: metric.reputation_score,
          percentage: nil
        }
      elsif metric.reputation_score <= thresholds[:reputation_score][:warning]
        violations_found << {
          metric: :reputation_score,
          threshold_type: :warning,
          threshold_value: thresholds[:reputation_score][:warning],
          actual_value: metric.reputation_score,
          percentage: nil
        }
      end

      return nil if violations_found.empty?

      # Determine overall severity (critical if any critical violation)
      severity = violations_found.any? { |v| v[:threshold_type] == :critical } ? :critical : :warning

      {
        ip_address: metric.ip_address,
        destination_domain: metric.destination_domain,
        sender_domain: metric.sender_domain,
        period: metric.period,
        period_date: metric.period_date,
        severity: severity,
        violations: violations_found,
        metric: metric
      }
    end

    # Take automated action based on violation
    # @param violation [Hash] The violation from check_thresholds
    # @param action_type [Symbol] :pause, :warn, or :notify
    def take_action(violation, action_type: nil)
      action_type ||= determine_action(violation)

      case action_type
      when :pause
        pause_ip_for_domain(violation)
      when :warn
        create_warning(violation)
      when :notify
        send_notification(violation)
      end
    end

    # Process violations and take appropriate actions
    # @param violations [Array<Hash>] Violations to process
    # @return [Hash] Summary of actions taken
    def process_violations(violations)
      summary = { paused: 0, warned: 0, notified: 0 }

      violations.each do |violation|
        action_type = determine_action(violation)
        take_action(violation, action_type: action_type)

        summary[action_type] += 1 if summary.key?(action_type)
      rescue StandardError => e
        logger.error "[ThresholdMonitor] Error processing violation: #{e.message}"
        logger.error e.backtrace.join("\n")
      end

      summary
    end

    private

    def load_config_thresholds
      config = Postal::Config.ip_reputation&.metrics&.thresholds
      return nil unless config

      {
        bounce_rate: {
          warning: config[:bounce_rate][:warning] || DEFAULT_THRESHOLDS[:bounce_rate][:warning],
          critical: config[:bounce_rate][:critical] || DEFAULT_THRESHOLDS[:bounce_rate][:critical]
        },
        spam_rate: {
          warning: config[:spam_rate][:warning] || DEFAULT_THRESHOLDS[:spam_rate][:warning],
          critical: config[:spam_rate][:critical] || DEFAULT_THRESHOLDS[:spam_rate][:critical]
        },
        delivery_rate: {
          warning: config[:delivery_rate][:warning] || DEFAULT_THRESHOLDS[:delivery_rate][:warning],
          critical: config[:delivery_rate][:critical] || DEFAULT_THRESHOLDS[:delivery_rate][:critical]
        },
        reputation_score: {
          warning: config[:reputation_score][:warning] || DEFAULT_THRESHOLDS[:reputation_score][:warning],
          critical: config[:reputation_score][:critical] || DEFAULT_THRESHOLDS[:reputation_score][:critical]
        }
      }
    rescue StandardError
      nil
    end

    def load_config_minimum_volume
      Postal::Config.postal.ip_reputation_threshold_monitoring_minimum_volume
    rescue StandardError
      nil
    end

    def determine_action(violation)
      if violation[:severity] == :critical
        :pause
      elsif violation[:severity] == :warning
        # Check if already warned recently
        recent_warning = IPHealthAction.where(
          ip_address: violation[:ip_address],
          action_type: IPHealthAction::MONITOR
        ).where("created_at >= ?", 1.hour.ago).exists?

        recent_warning ? :notify : :warn
      else
        :notify
      end
    end

    def pause_ip_for_domain(violation)
      return unless violation[:destination_domain].present?

      # Check if already paused
      exclusion = IPDomainExclusion.find_by(
        ip_address: violation[:ip_address],
        destination_domain: violation[:destination_domain]
      )

      if exclusion
        # Already paused or in warmup - move back to warmup_stage 0 if needed
        if exclusion.warmup_stage > 0
          logger.info "[ThresholdMonitor] Resetting IP #{violation[:ip_address].ipv4} warmup_stage to 0 for #{violation[:destination_domain]}"
          exclusion.update!(warmup_stage: 0)
        end
      else
        # Create new pause
        logger.info "[ThresholdMonitor] Pausing IP #{violation[:ip_address].ipv4} for #{violation[:destination_domain]}"

        IPDomainExclusion.create!(
          ip_address: violation[:ip_address],
          destination_domain: violation[:destination_domain],
          warmup_stage: 0,
          excluded_at: Time.current,
          reason: format_violation_reason(violation)
        )
      end

      # Log action
      IPHealthAction.create!(
        ip_address: violation[:ip_address],
        action_type: IPHealthAction::PAUSE,
        reason: format_violation_reason(violation),
      )

      # Send notification
      send_notification(violation, action_taken: "paused")
    end

    def create_warning(violation)
      logger.warn "[ThresholdMonitor] Warning threshold exceeded for IP #{violation[:ip_address].ipv4}"

      IPHealthAction.create!(
        ip_address: violation[:ip_address],
        action_type: IPHealthAction::MONITOR,
        reason: format_violation_reason(violation),
      )

      send_notification(violation, action_taken: "warning_logged")
    end

    def send_notification(violation, action_taken: "notified")
      IPBlacklist::Notifier.notify(
        event: :threshold_violation,
        ip_address: violation[:ip_address],
      )
    rescue StandardError => e
      logger.error "[ThresholdMonitor] Failed to send notification: #{e.message}"
    end

    def format_violation_reason(violation)
      violations_text = violation[:violations].map do |v|
        "#{v[:metric]}: #{v[:percentage] ? "#{v[:percentage].round(2)}%" : v[:actual_value]}"
      end.join(", ")

      "Threshold violation (#{violation[:severity]}): #{violations_text}"
    end

  end
end
