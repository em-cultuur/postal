# frozen_string_literal: true

class MXRateLimitsController < ApplicationController

  include WithinOrganization

  before_action { @server = organization.servers.present.find_by_permalink!(params[:server_id]) }

  def index
    @rate_limits = @server.mx_rate_limits.active.includes(:events).order(current_delay: :desc)

    respond_to do |wants|
      wants.html
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
    rate_limit = @server.mx_rate_limits.find_by(mx_domain: mx_domain)

    if rate_limit.nil?
      respond_to do |wants|
        wants.json do
          render json: { error: "Rate limit not found for MX domain: #{mx_domain}" }, status: :not_found
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
            last_error_message: rate_limit.last_error_message,
            created_at: rate_limit.created_at,
            updated_at: rate_limit.updated_at
          },
          events_last_24h: recent_events.map do |event|
            {
              event_type: event.event_type,
              smtp_response: event.smtp_response,
              created_at: event.created_at
            }
          end
        }
      end
    end
  end

end
