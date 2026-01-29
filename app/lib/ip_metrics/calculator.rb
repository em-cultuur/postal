# frozen_string_literal: true

module IPMetrics
  # Enhanced reputation score calculation with configurable weights and thresholds
  # Provides detailed analysis of IP health based on multiple factors
  class Calculator

    # Default scoring weights (sum should be 100)
    DEFAULT_WEIGHTS = {
      delivery_rate: 40,      # Weight for successful deliveries
      bounce_rate: 30,        # Weight for bounce rate penalty
      spam_rate: 20,          # Weight for spam complaints penalty
      consistency: 10         # Weight for delivery consistency
    }.freeze

    # Reputation score thresholds
    SCORE_EXCELLENT = 90..100
    SCORE_GOOD = 75..89
    SCORE_FAIR = 60..74
    SCORE_POOR = 40..59
    SCORE_CRITICAL = 0..39

    # Rate thresholds (stored as integers * 10000)
    BOUNCE_RATE_EXCELLENT = 200      # < 2%
    BOUNCE_RATE_ACCEPTABLE = 500     # < 5%
    BOUNCE_RATE_WARNING = 1000       # < 10%
    BOUNCE_RATE_CRITICAL = 2000      # >= 20%

    SPAM_RATE_EXCELLENT = 10         # < 0.1%
    SPAM_RATE_ACCEPTABLE = 100       # < 1%
    SPAM_RATE_WARNING = 300          # < 3%

    DELIVERY_RATE_EXCELLENT = 9800   # > 98%
    DELIVERY_RATE_ACCEPTABLE = 9500  # > 95%
    DELIVERY_RATE_WARNING = 9000     # > 90%

    class << self

      # Calculate comprehensive reputation score for a metric
      # @param metric [IPReputationMetric] The metric to score
      # @param weights [Hash] Optional custom weights
      # @return [Integer] Score from 0-100
      def calculate_reputation_score(metric, weights: DEFAULT_WEIGHTS)
        return 100 if metric.sent_count.zero? # No data = assume good

        score = 0.0

        # Component 1: Delivery rate (higher is better)
        delivery_component = calculate_delivery_component(metric.delivery_rate, weights[:delivery_rate])
        score += delivery_component

        # Component 2: Bounce rate (lower is better)
        bounce_component = calculate_bounce_component(metric.bounce_rate, weights[:bounce_rate])
        score += bounce_component

        # Component 3: Spam rate (lower is better)
        spam_component = calculate_spam_component(metric.spam_rate, weights[:spam_rate])
        score += spam_component

        # Component 4: Consistency (based on hard vs soft failures)
        consistency_component = calculate_consistency_component(metric, weights[:consistency])
        score += consistency_component

        # Ensure score is within bounds
        score.clamp(0, 100).round
      end

      # Calculate all rates for a metric
      # @param metric [IPReputationMetric] The metric to calculate rates for
      def calculate_rates(metric)
        return if metric.sent_count.zero?

        metric.bounce_rate = ((metric.bounced_count.to_f / metric.sent_count) * 10_000).to_i
        metric.delivery_rate = ((metric.delivered_count.to_f / metric.sent_count) * 10_000).to_i
        metric.spam_rate = ((metric.spam_complaint_count.to_f / metric.sent_count) * 10_000).to_i
      end

      # Get reputation status as symbol
      def reputation_status(score)
        case score
        when SCORE_EXCELLENT then :excellent
        when SCORE_GOOD then :good
        when SCORE_FAIR then :fair
        when SCORE_POOR then :poor
        when SCORE_CRITICAL then :critical
        else :unknown
        end
      end

      # Check if bounce rate exceeds threshold
      def bounce_rate_status(bounce_rate)
        case bounce_rate
        when 0...BOUNCE_RATE_EXCELLENT then :excellent
        when BOUNCE_RATE_EXCELLENT...BOUNCE_RATE_ACCEPTABLE then :acceptable
        when BOUNCE_RATE_ACCEPTABLE...BOUNCE_RATE_WARNING then :warning
        when BOUNCE_RATE_WARNING...BOUNCE_RATE_CRITICAL then :poor
        else :critical
        end
      end

      # Check if spam rate exceeds threshold
      def spam_rate_status(spam_rate)
        case spam_rate
        when 0...SPAM_RATE_EXCELLENT then :excellent
        when SPAM_RATE_EXCELLENT...SPAM_RATE_ACCEPTABLE then :acceptable
        when SPAM_RATE_ACCEPTABLE...SPAM_RATE_WARNING then :warning
        else :critical
        end
      end

      # Check if delivery rate meets threshold
      def delivery_rate_status(delivery_rate)
        case delivery_rate
        when DELIVERY_RATE_EXCELLENT.. then :excellent
        when DELIVERY_RATE_ACCEPTABLE...DELIVERY_RATE_EXCELLENT then :acceptable
        when DELIVERY_RATE_WARNING...DELIVERY_RATE_ACCEPTABLE then :warning
        else :critical
        end
      end

      # Analyze metric and return recommendations
      def analyze_metric(metric)
        return { status: :no_data, recommendations: [] } if metric.sent_count.zero?

        recommendations = []
        issues = []

        # Check bounce rate
        bounce_status = bounce_rate_status(metric.bounce_rate)
        if bounce_status == :critical
          issues << "Critical bounce rate (#{metric.bounce_rate_percentage.round(2)}%)"
          recommendations << "Immediately pause sending and investigate recipient list quality"
        elsif [:poor, :warning].include?(bounce_status)
          issues << "High bounce rate (#{metric.bounce_rate_percentage.round(2)}%)"
          recommendations << "Review recipient list quality and validation processes"
        end

        # Check spam rate
        spam_status = spam_rate_status(metric.spam_rate)
        if spam_status == :critical
          issues << "Critical spam complaint rate (#{metric.spam_rate_percentage.round(2)}%)"
          recommendations << "Stop sending immediately and review content and recipient consent"
        elsif spam_status == :warning
          issues << "Elevated spam complaints (#{metric.spam_rate_percentage.round(2)}%)"
          recommendations << "Review email content, unsubscribe process, and targeting"
        end

        # Check delivery rate
        delivery_status = delivery_rate_status(metric.delivery_rate)
        if delivery_status == :critical
          issues << "Very low delivery rate (#{metric.delivery_rate_percentage.round(2)}%)"
          recommendations << "IP reputation severely damaged - consider IP warmup or rotation"
        elsif delivery_status == :warning
          issues << "Low delivery rate (#{metric.delivery_rate_percentage.round(2)}%)"
          recommendations << "Monitor closely and consider implementing IP warmup"
        end

        # Check hard vs soft failure ratio
        if metric.hard_fail_count > metric.soft_fail_count * 2
          issues << "High ratio of hard failures to soft failures"
          recommendations << "Many permanent failures detected - clean your recipient list"
        end

        # Overall status
        rep_status = reputation_status(metric.reputation_score)

        {
          status: rep_status,
          score: metric.reputation_score,
          issues: issues,
          recommendations: recommendations,
          bounce_status: bounce_status,
          spam_status: spam_status,
          delivery_status: delivery_status
        }
      end

      # Calculate trend by comparing recent metrics
      # @param metrics [Array<IPReputationMetric>] Ordered by period_date DESC
      # @return [Hash] Trend analysis
      def calculate_trend(metrics)
        return { trend: :insufficient_data } if metrics.size < 2

        latest = metrics.first
        previous = metrics[1]

        score_change = latest.reputation_score - previous.reputation_score
        bounce_change = latest.bounce_rate - previous.bounce_rate
        delivery_change = latest.delivery_rate - previous.delivery_rate

        # Determine overall trend
        if score_change.abs < 5
          trend = :stable
        elsif score_change > 0
          trend = :improving
        else
          trend = :degrading
        end

        {
          trend: trend,
          score_change: score_change,
          bounce_rate_change: bounce_change,
          delivery_rate_change: delivery_change,
          latest_score: latest.reputation_score,
          previous_score: previous.reputation_score
        }
      end

      private

      # Calculate delivery rate component of reputation score
      def calculate_delivery_component(delivery_rate, weight)
        # Normalize delivery rate (0-10000) to 0-1 scale
        normalized = delivery_rate / 10_000.0

        # Apply weight
        normalized * weight
      end

      # Calculate bounce rate component (penalty)
      def calculate_bounce_component(bounce_rate, weight)
        # Bounce rate should reduce score
        # Use logarithmic scale to heavily penalize high bounce rates

        if bounce_rate <= BOUNCE_RATE_EXCELLENT
          # Excellent: full points
          weight
        elsif bounce_rate <= BOUNCE_RATE_ACCEPTABLE
          # Acceptable: 80% of points
          weight * 0.8
        elsif bounce_rate <= BOUNCE_RATE_WARNING
          # Warning: 50% of points
          weight * 0.5
        elsif bounce_rate <= BOUNCE_RATE_CRITICAL
          # Poor: 20% of points
          weight * 0.2
        else
          # Critical: 0 points
          0
        end
      end

      # Calculate spam rate component (penalty)
      def calculate_spam_component(spam_rate, weight)
        # Spam complaints are very serious
        # Use steep penalty curve

        if spam_rate <= SPAM_RATE_EXCELLENT
          # Excellent: full points
          weight
        elsif spam_rate <= SPAM_RATE_ACCEPTABLE
          # Acceptable: 60% of points
          weight * 0.6
        elsif spam_rate <= SPAM_RATE_WARNING
          # Warning: 20% of points
          weight * 0.2
        else
          # Critical: 0 points
          0
        end
      end

      # Calculate consistency component based on failure patterns
      def calculate_consistency_component(metric, weight)
        return weight if metric.bounced_count.zero? # Perfect consistency

        total_failures = metric.bounced_count
        hard_fail_ratio = metric.hard_fail_count.to_f / total_failures

        # Prefer soft failures over hard failures (soft are temporary, hard are permanent)
        # High hard failure ratio indicates list quality issues

        if hard_fail_ratio < 0.2
          # < 20% hard failures: excellent consistency
          weight
        elsif hard_fail_ratio < 0.5
          # < 50% hard failures: acceptable
          weight * 0.7
        elsif hard_fail_ratio < 0.8
          # < 80% hard failures: concerning
          weight * 0.4
        else
          # >= 80% hard failures: major list quality issues
          0
        end
      end

    end

  end
end
