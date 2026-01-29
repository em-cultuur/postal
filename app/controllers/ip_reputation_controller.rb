# frozen_string_literal: true

# IP Reputation Management Dashboard Controller
# Provides overview, health status, and trend analysis for IP reputation
class IPReputationController < ApplicationController

  before_action :admin_required

  # GET /ip_reputation
  # Main index redirects to dashboard
  def index
    redirect_to dashboard_ip_reputation_index_path
  end

  # GET /ip_reputation/dashboard
  # Overview dashboard with key metrics and alerts
  def dashboard
    @stats = calculate_dashboard_stats
    @recent_blacklists = IPBlacklistRecord.active.includes(:ip_address).order(created_at: :desc).limit(10)
    @recent_actions = IPHealthAction.includes(:ip_address, :user).order(created_at: :desc).limit(10)
    @critical_ips = find_critical_ips
    @warming_ips = IPDomainExclusion.warming.includes(:ip_address).order(next_warmup_at: :asc).limit(10)

    respond_to do |format|
      format.html
      format.json { render json: dashboard_json }
    end
  end

  # GET /ip_reputation/health
  # Real-time health status for all IPs
  def health
    @page = (params[:page] || 1).to_i
    @per_page = (params[:per_page] || 50).to_i.clamp(1, 100)

    scope = IPAddress.includes(:ip_pool, :ip_reputation_metrics, :ip_blacklist_records, :ip_domain_exclusions)

    # Apply filters
    scope = scope.where(ip_pool_id: params[:ip_pool_id]) if params[:ip_pool_id].present?

    @total_count = scope.count
    @total_pages = (@total_count.to_f / @per_page).ceil
    @ips = scope.order(created_at: :desc).limit(@per_page).offset((@page - 1) * @per_page)
    @ip_pools = IPPool.all

    respond_to do |format|
      format.html
      format.json do
        render json: {
          ips: @ips.map { |ip| ip_health_summary(ip) },
          pagination: { page: @page, per_page: @per_page, total: @total_count, pages: @total_pages },
          updated_at: Time.current
        }
      end
    end
  end

  # GET /ip_reputation/trends
  # Historical trends and metrics analysis
  def trends
    @period = params[:period] || "daily"
    @days = (params[:days] || 30).to_i.clamp(1, 90)

    @metrics = IPReputationMetric
               .where("created_at >= ?", @days.days.ago)
               .includes(:ip_address)
               .order(created_at: :desc)

    @trends = calculate_trends_summary(@metrics, @days)
    @top_ips = find_top_ips(@metrics)
    @blacklist_activity = calculate_blacklist_activity(@days)

    respond_to do |format|
      format.html
      format.json { render json: { trends: @trends, top_ips: @top_ips, blacklist_activity: @blacklist_activity } }
    end
  end

  private

  def calculate_dashboard_stats
    {
      total_ips: IPAddress.count,
      healthy_ips: count_healthy_ips,
      paused_ips: IPDomainExclusion.paused.select(:ip_address_id).distinct.count,
      warming_ips: IPDomainExclusion.warming.select(:ip_address_id).distinct.count,
      blacklisted_ips: IPBlacklistRecord.active.select(:ip_address_id).distinct.count,
      critical_domains: count_critical_domains,
      recent_actions: IPHealthAction.where("created_at >= ?", 24.hours.ago).count,
      avg_reputation_score: calculate_avg_reputation_score
    }
  end

  def count_healthy_ips
    total = IPAddress.count
    problematic = IPDomainExclusion.select(:ip_address_id).distinct.count +
                  IPBlacklistRecord.active.select(:ip_address_id).distinct.count
    [total - problematic, 0].max
  end

  def count_critical_domains
    IPReputationMetric
      .internal_metrics
      .where("period_date >= ?", 7.days.ago)
      .where("reputation_score < ?", 40)
      .select(:destination_domain)
      .distinct
      .count
  end

  def calculate_avg_reputation_score
    recent_metrics = IPReputationMetric
                     .internal_metrics
                     .where("period_date >= ?", 7.days.ago)
                     .average(:reputation_score)

    recent_metrics&.round(1) || 100.0
  end

  def find_critical_ips
    # Find IPs with critical reputation scores or multiple recent blacklistings
    critical_metrics = IPReputationMetric
                       .internal_metrics
                       .where("period_date >= ?", 7.days.ago)
                       .where("reputation_score < ?", 40)
                       .includes(:ip_address)
                       .group_by(&:ip_address_id)

    critical_metrics.map do |ip_id, metrics|
      ip = metrics.first.ip_address
      {
        ip_address: ip,
        avg_score: metrics.map(&:reputation_score).sum / metrics.size,
        affected_domains: metrics.map(&:destination_domain).compact.uniq.size,
        metrics_count: metrics.size
      }
    end.sort_by { |data| data[:avg_score] }.first(10)
  end

  def ip_health_summary(ip)
    # Get current health status for an IP
    active_blacklists = ip.ip_blacklist_records.active.count
    paused_domains = ip.ip_domain_exclusions.paused.count
    warming_domains = ip.ip_domain_exclusions.warming.count

    recent_metric = ip.ip_reputation_metrics
                      .internal_metrics
                      .for_period("daily")
                      .where("period_date >= ?", 1.day.ago)
                      .order(period_date: :desc)
                      .first

    status = determine_health_status(active_blacklists, paused_domains, recent_metric)

    {
      id: ip.id,
      ipv4: ip.ipv4,
      ipv6: ip.ipv6,
      hostname: ip.hostname,
      pool: ip.ip_pool&.name,
      status: status,
      active_blacklists: active_blacklists,
      paused_domains: paused_domains,
      warming_domains: warming_domains,
      reputation_score: recent_metric&.reputation_score,
      last_checked: recent_metric&.period_date
    }
  end

  def determine_health_status(blacklists, paused, metric)
    return "critical" if blacklists > 0 || (metric && metric.reputation_score < 40)
    return "warning" if paused > 0 || (metric && metric.reputation_score < 60)
    return "warming" if paused == 0 && metric && metric.reputation_score < 80

    "healthy"
  end

  def dashboard_json
    {
      stats: @stats,
      recent_blacklists: @recent_blacklists.map do |bl|
        {
          id: bl.id,
          ip: bl.ip_address.ipv4,
          blacklist: bl.blacklist_source,
          domain: bl.destination_domain,
          detected_at: bl.created_at,
          status: bl.status
        }
      end,
      critical_ips: @critical_ips,
      warming_ips: @warming_ips.map do |excl|
        {
          ip: excl.ip_address.ipv4,
          domain: excl.destination_domain,
          stage: excl.warmup_stage,
          next_advancement: excl.next_warmup_at,
          reason: excl.reason
        }
      end,
      generated_at: Time.current
    }
  end

  def calculate_trend_data(metrics)
    # Group metrics by date and calculate aggregates
    by_date = metrics.group_by(&:period_date)

    dates = by_date.keys.sort
    {
      dates: dates,
      avg_reputation: dates.map { |date| by_date[date].map(&:reputation_score).sum / by_date[date].size },
      avg_bounce_rate: dates.map { |date| (by_date[date].map(&:bounce_rate).sum / by_date[date].size / 100.0).round(2) },
      avg_spam_rate: dates.map { |date| (by_date[date].map(&:spam_rate).sum / by_date[date].size / 100.0).round(2) },
      total_sent: dates.map { |date| by_date[date].map(&:sent_count).sum },
      total_delivered: dates.map { |date| by_date[date].map(&:delivered_count).sum },
      total_bounced: dates.map { |date| by_date[date].map(&:bounced_count).sum }
    }
  end

  def calculate_trends_summary(metrics, days)
    return default_trends_summary if metrics.empty?

    {
      avg_reputation_score: metrics.average(:reputation_score)&.round(1),
      avg_delivery_rate: metrics.average(:delivery_rate)&.round(1) || 0,
      avg_bounce_rate: metrics.average(:bounce_rate)&.round(1) || 0,
      total_blacklist_events: IPBlacklistRecord.where("detected_at >= ?", days.days.ago).count
    }
  end

  def default_trends_summary
    {
      avg_reputation_score: nil,
      avg_delivery_rate: 0,
      avg_bounce_rate: 0,
      total_blacklist_events: 0
    }
  end

  def find_top_ips(metrics)
    # Group by IP and get average scores
    by_ip = metrics.group_by(&:ip_address_id)

    top_data = by_ip.map do |ip_id, ip_metrics|
      latest = ip_metrics.max_by(&:created_at)
      {
        ip: latest.ip_address,
        score: ip_metrics.average { |m| m.reputation_score }.round(1),
        delivery_rate: ip_metrics.average { |m| m.delivery_rate }.round(1),
        bounce_rate: ip_metrics.average { |m| m.bounce_rate }.round(1),
        spam_rate: ip_metrics.average { |m| m.spam_rate }.round(1),
        updated_at: latest.created_at
      }
    end

    top_data.sort_by { |d| -d[:score] }.first(10)
  end

  def calculate_blacklist_activity(days)
    # Group blacklist events by day
    start_date = days.days.ago.to_date
    end_date = Date.today

    (start_date..end_date).map do |date|
      new_count = IPBlacklistRecord.where(detected_at: date.beginning_of_day..date.end_of_day).count
      resolved_count = IPBlacklistRecord.where(resolved_at: date.beginning_of_day..date.end_of_day).count

      {
        date: date,
        new_count: new_count,
        resolved_count: resolved_count
      }
    end.last(30) # Last 30 days only
  end

end
