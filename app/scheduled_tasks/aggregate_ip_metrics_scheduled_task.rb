# frozen_string_literal: true

# Scheduled task to aggregate IP reputation metrics from MessageDB deliveries
# Runs hourly to collect delivery statistics and update IPReputationMetric records
class AggregateIPMetricsScheduledTask < ApplicationScheduledTask

  def call
    logger.info "[IP METRICS] Starting IP reputation metrics aggregation"

    start_time = Time.current

    begin
      # Aggregate hourly metrics (current + previous hour for safety)
      logger.info "[IP METRICS] Aggregating hourly metrics..."
      IPMetrics::Aggregator.aggregate(period: IPReputationMetric::HOURLY, period_date: Time.current)
      IPMetrics::Aggregator.aggregate(period: IPReputationMetric::HOURLY, period_date: 1.hour.ago)

      # Aggregate daily metrics (today + yesterday for completion)
      logger.info "[IP METRICS] Aggregating daily metrics..."
      IPMetrics::Aggregator.aggregate(period: IPReputationMetric::DAILY, period_date: Date.current)
      IPMetrics::Aggregator.aggregate(period: IPReputationMetric::DAILY, period_date: Date.yesterday)

      # Monitor thresholds and trigger actions if needed
      if Postal::Config.ip_reputation&.metrics&.threshold_monitoring_enabled != false
        logger.info "[IP METRICS] Running threshold monitoring..."
        monitor_thresholds
      end

      duration = Time.current - start_time
      logger.info "[IP METRICS] Aggregation completed in #{duration.round(2)}s"
    rescue StandardError => e
      logger.error "[IP METRICS] Error during aggregation: #{e.message}"
      logger.error e.backtrace.join("\n")
    end
  end

  # Run every hour at 5 minutes past the hour
  def self.next_run_after
    time = Time.current
    time = time.change(min: 5, sec: 0)
    time += 1.hour if time < Time.current
    time
  end

  private

  def monitor_thresholds
    # Get recent metrics (last 24 hours) to identify problematic IPs
    metrics = IPReputationMetric
              .internal_metrics
              .for_period(IPReputationMetric::HOURLY)
              .where("period_date >= ?", 24.hours.ago)
              .includes(:ip_address)

    metrics.each do |metric|
      next if metric.sent_count < minimum_volume_threshold

      analysis = metric.analyze

      # Take action if critical issues detected
      if analysis[:status] == :critical || analysis[:bounce_status] == :critical
        logger.warn "[IP METRICS] Critical status detected for IP #{metric.ip_address.ipv4} to domain #{metric.destination_domain}"
        logger.warn "[IP METRICS] Issues: #{analysis[:issues].join(', ')}"

        handle_critical_metric(metric, analysis)
      elsif analysis[:status] == :poor
        logger.info "[IP METRICS] Poor reputation detected for IP #{metric.ip_address.ipv4} to domain #{metric.destination_domain}"

        handle_poor_metric(metric, analysis)
      end
    end
  end

  def handle_critical_metric(metric, analysis)
    return unless metric.destination_domain.present?

    # Check if IP is already paused for this domain
    exclusion = IPDomainExclusion.find_by(
      ip_address_id: metric.ip_address_id,
      destination_domain: metric.destination_domain
    )

    if exclusion && exclusion.warmup_stage > 0
      # Already in warmup/recovery - pause it back to warmup_stage 0
      logger.info "[IP METRICS] Moving IP back to warmup_stage 0 due to critical metrics"
      exclusion.update!(warmup_stage: 0)
    elsif exclusion.nil?
      # Not yet paused - pause it now
      logger.info "[IP METRICS] Creating new IP pause due to critical metrics"

      IPDomainExclusion.create!(
        ip_address: metric.ip_address,
        destination_domain: metric.destination_domain,
        warmup_stage: 0,
        excluded_at: Time.current,
        reason: "Critical reputation metrics: #{analysis[:issues].first}"
      )

      # Log health action
      health_action = IPHealthAction.create!(
        ip_address: metric.ip_address,
        action_type: IPHealthAction::PAUSE,
        reason: "Critical reputation: #{analysis[:issues].join('; ')}"
      )

      # Send notification
      begin
        notifier = IPBlacklist::Notifier.new
        notifier.notify_ip_paused(
          metric.ip_address,
          metric.destination_domain,
          "Critical reputation metrics: #{analysis[:issues].first}",
          health_action
        )
      rescue StandardError => e
        logger.error "[IP METRICS] Failed to send notification: #{e.message}"
      end
    end
  end

  def handle_poor_metric(metric, analysis)
    # Log warning but don't pause (not critical yet)
    # Create advisory health action for visibility

    IPHealthAction.create!(
      ip_address: metric.ip_address,
      action_type: IPHealthAction::MONITOR,
      reason: "Poor reputation metrics: #{analysis[:issues].join('; ')}"
    )
  end

  def minimum_volume_threshold
    # Only monitor IPs with meaningful send volume
    # Default: at least 10 messages in the period
    Postal::Config.ip_reputation&.metrics&.minimum_volume || 10
  end

end
