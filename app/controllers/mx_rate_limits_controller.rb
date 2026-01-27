# frozen_string_literal: true

class MXRateLimitsController < ApplicationController

  include WithinOrganization

  before_action { @server = organization.servers.present.find_by_permalink!(params[:server_id]) }

  def index
    @rate_limits = @server.mx_rate_limits.active.order(current_delay: :desc)

    respond_to do |wants|
      wants.html do
        # Load dashboard data for HTML view
        @summary = {
          active_count: @server.mx_rate_limits.active.count,
          total_count: @server.mx_rate_limits.count,
          max_delay: @server.mx_rate_limits.maximum(:current_delay) || 0,
          avg_delay: @server.mx_rate_limits.average(:current_delay)&.round || 0
        }
        @recent_events = @server.mx_rate_limit_events.where("created_at > ?", 24.hours.ago).order(created_at: :desc).limit(50)
        @events_chart_data = prepare_events_chart_data
        render :dashboard
      end
      wants.json do
        render json: {
          rate_limits: @rate_limits.map do |rl|
            {
              mx_domain: rl.mx_domain,
              current_delay_seconds: rl.current_delay,
              error_count: rl.error_count,
              success_count: rl.success_count,
              last_error_at: rl.last_error_at,
              last_success_at: rl.last_success_at,
              last_error_message: rl.last_error_message,
              created_at: rl.created_at,
              updated_at: rl.updated_at
            }
          end
        }
      end
    end
  end

  def dashboard
    # Legacy dashboard action - now handled by index
    redirect_to organization_server_mx_rate_limits_path(@organization, @server)
  end

  def whitelists
    @whitelists = @server.mx_rate_limit_whitelists.order(created_at: :desc)

    respond_to do |wants|
      wants.html do
        render :whitelists
      end
      wants.json do
        render json: {
          whitelists: @whitelists.map do |wl|
            {
              id: wl.id,
              mx_domain: wl.mx_domain,
              pattern_type: wl.pattern_type,
              description: wl.description,
              created_by: wl.created_by&.email,
              created_at: wl.created_at,
              updated_at: wl.updated_at
            }
          end
        }
      end
    end
  end

  def create_whitelist
    mx_domain = params[:mx_domain]
    pattern_type = params[:pattern_type] || "exact"
    description = params[:description]

    # Validate domain format
    unless mx_domain.match?(/\A[a-zA-Z0-9.*-]{1,255}\z/)
      respond_to do |wants|
        wants.json do
          render json: { error: "Invalid domain format" }, status: :unprocessable_entity
        end
      end
      return
    end

    # Validate pattern type
    unless MXRateLimitWhitelist::PATTERN_TYPES.values.include?(pattern_type)
      respond_to do |wants|
        wants.json do
          render json: { error: "Invalid pattern type" }, status: :unprocessable_entity
        end
      end
      return
    end

    whitelist = @server.mx_rate_limit_whitelists.build(
      mx_domain: mx_domain,
      pattern_type: pattern_type,
      description: description,
      created_by: current_user
    )

    if whitelist.save
      respond_to do |wants|
        wants.json do
          render json: {
            whitelist: {
              id: whitelist.id,
              mx_domain: whitelist.mx_domain,
              pattern_type: whitelist.pattern_type,
              description: whitelist.description,
              created_by: whitelist.created_by&.email,
              created_at: whitelist.created_at
            }
          }, status: :created
        end
      end
    else
      respond_to do |wants|
        wants.json do
          render json: { error: whitelist.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end
      end
    end
  end

  def delete_whitelist
    whitelist_id = params[:id]
    whitelist = @server.mx_rate_limit_whitelists.find_by(id: whitelist_id)

    if whitelist.nil?
      respond_to do |wants|
        wants.json do
          render json: { error: "Whitelist entry not found" }, status: :not_found
        end
      end
      return
    end

    whitelist.destroy

    respond_to do |wants|
      wants.json do
        render json: { message: "Whitelist entry deleted" }, status: :ok
      end
    end
  end

  def summary
    active_count = @server.mx_rate_limits.active.count
    total_count = @server.mx_rate_limits.count
    recent_events_count = @server.mx_rate_limit_events.where("created_at > ?", 24.hours.ago).count
    recent_errors = @server.mx_rate_limit_events.where("created_at > ?", 24.hours.ago).where(event_type: "error").count
    recent_successes = @server.mx_rate_limit_events.where("created_at > ?", 24.hours.ago).where(event_type: "success").count

    respond_to do |wants|
      wants.json do
        render json: {
          summary: {
            active_rate_limits: active_count,
            total_rate_limits: total_count,
            events_last_24h: recent_events_count,
            errors_last_24h: recent_errors,
            successes_last_24h: recent_successes
          }
        }
      end
    end
  end

  def stats
    mx_domain = params[:id]

    # Validate domain format to prevent injection attacks
    unless mx_domain.match?(/\A[a-zA-Z0-9.-]{1,255}\z/)
      respond_to do |wants|
        wants.json do
          render json: { error: "Invalid request" }, status: :unprocessable_entity
        end
      end
      return
    end

    rate_limit = @server.mx_rate_limits.find_by(mx_domain: mx_domain)

    if rate_limit.nil?
      respond_to do |wants|
        wants.json do
          render json: { error: "Not found" }, status: :not_found
        end
      end
      return
    end

    recent_events = rate_limit.events.where("created_at > ?", 24.hours.ago).order(created_at: :desc).limit(100)

    respond_to do |wants|
      wants.json do
        render json: {
           rate_limit: {
             mx_domain: rate_limit.mx_domain,
             current_delay_seconds: rate_limit.current_delay,
             error_count: rate_limit.error_count,
             success_count: rate_limit.success_count,
             last_error_at: rate_limit.last_error_at,
             last_success_at: rate_limit.last_success_at,
             last_error_message: sanitize_smtp_response(rate_limit.last_error_message),
             created_at: rate_limit.created_at,
             updated_at: rate_limit.updated_at
           },
           events_last_24h: recent_events.map do |event|
             {
               event_type: event.event_type,
               smtp_response: sanitize_smtp_response(event.smtp_response),
               created_at: event.created_at
             }
           end
        }
      end
    end
  end

  private

  # Sanitize SMTP responses to prevent infrastructure disclosure
  # Extracts only the response code (e.g., "421") from the full message
  # Returns nil if the response is blank or invalid
  #
  # @param response [String] the full SMTP response
  # @return [String, nil] just the response code or nil
  def sanitize_smtp_response(response)
    return nil if response.blank?

    # Extract just the response code (first 3 digits)
    match = response.match(/\A(\d{3})/)
    match ? match[1] : nil
  end

  def prepare_events_chart_data
    events = @server.mx_rate_limit_events.where("created_at > ?", 48.hours.ago).order(created_at: :asc)

    hourly_data = {}
    events.each do |event|
      hour = event.created_at.beginning_of_hour
      hourly_data[hour] ||= { errors: 0, successes: 0, delays: 0 }
      case event.event_type
      when "error"
        hourly_data[hour][:errors] += 1
      when "success"
        hourly_data[hour][:successes] += 1
      when "delay_increased", "delay_decreased"
        hourly_data[hour][:delays] += 1
      end
    end

    # Fill in missing hours
    start_time = 48.hours.ago.beginning_of_hour
    end_time = Time.current.beginning_of_hour
    current_time = start_time

    while current_time <= end_time
      hourly_data[current_time] ||= { errors: 0, successes: 0, delays: 0 }
      current_time += 1.hour
    end

    hourly_data.sort_by { |k, _| k }
  end

  def prepare_chart_json
    chart_data = prepare_events_chart_data
    labels = chart_data.map { |hour, _| hour.strftime("%l%P") }
    errors = chart_data.map { |_, data| data[:errors] }
    successes = chart_data.map { |_, data| data[:successes] }

    {
      labels: labels,
      errors: errors,
      successes: successes
    }
  end

  helper_method :prepare_chart_json

  # Format delay in seconds to human-readable format
  #
  # @param seconds [Integer] the number of seconds
  # @return [String] human-readable format (e.g., "5m", "1h", "No delay")
  def format_delay_human(seconds)
    return "No delay" if seconds.zero?

    case seconds
    when 1..59
      "#{seconds}s"
    when 60..3599
      minutes = (seconds / 60.0).round(1)
      minutes == minutes.to_i ? "#{minutes.to_i}m" : "#{minutes}m"
    else
      hours = (seconds / 3600.0).round(1)
      hours == hours.to_i ? "#{hours.to_i}h" : "#{hours}h"
    end
  end

  helper_method :format_delay_human

end
