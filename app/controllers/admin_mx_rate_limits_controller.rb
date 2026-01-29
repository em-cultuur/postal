# frozen_string_literal: true

class AdminMXRateLimitsController < ApplicationController

  before_action :admin_required

  def index
    # Load all organizations with their servers and active MX rate limits
    @organizations = Organization.present
                                 .includes(servers: :mx_rate_limits)
                                 .order(:name)
                                 .to_a

    # Calculate system-wide MX rate limiting statistics
    calculate_mx_rate_limit_totals

    # Prepare data grouped by organization
    @organization_data = prepare_organization_data
  end

  private

  def calculate_mx_rate_limit_totals
    @total_active_rate_limits = 0
    @total_rate_limits = 0
    @total_max_delay = 0
    @total_error_count = 0
    @total_success_count = 0
    @organizations_with_rate_limits = 0
    @servers_with_rate_limits = 0

    @organizations.each do |organization|
      org_has_rate_limits = false

      organization.servers.present.each do |server|
        rate_limits = server.mx_rate_limits.to_a
        active_rate_limits = rate_limits.select { |rl| rl.current_delay.positive? }

        next if rate_limits.empty?

        org_has_rate_limits = true
        @servers_with_rate_limits += 1 if active_rate_limits.any?

        @total_rate_limits += rate_limits.size
        @total_active_rate_limits += active_rate_limits.size

        # Find max delay across all rate limits
        max_delay = rate_limits.map(&:current_delay).max || 0
        @total_max_delay = max_delay if max_delay > @total_max_delay

        # Sum error and success counts
        @total_error_count += rate_limits.sum(&:error_count)
        @total_success_count += rate_limits.sum(&:success_count)
      end

      @organizations_with_rate_limits += 1 if org_has_rate_limits
    end
  end

  def prepare_organization_data
    data = []

    @organizations.each do |organization|
      org_rate_limits = []
      org_total_active = 0
      org_total_rate_limits = 0
      org_max_delay = 0
      org_total_errors = 0
      org_total_successes = 0

      organization.servers.present.each do |server|
        rate_limits = server.mx_rate_limits.to_a
        active_rate_limits = rate_limits.select { |rl| rl.current_delay.positive? }

        next if rate_limits.empty?

        # Calculate server-level statistics
        server_active_count = active_rate_limits.size
        server_total_count = rate_limits.size
        server_max_delay = rate_limits.map(&:current_delay).max || 0
        server_avg_delay = active_rate_limits.any? ? (active_rate_limits.sum(&:current_delay) / active_rate_limits.size.to_f).round : 0
        server_error_count = rate_limits.sum(&:error_count)
        server_success_count = rate_limits.sum(&:success_count)

        # Update organization totals
        org_total_active += server_active_count
        org_total_rate_limits += server_total_count
        org_max_delay = server_max_delay if server_max_delay > org_max_delay
        org_total_errors += server_error_count
        org_total_successes += server_success_count

        # Store server data
        org_rate_limits << {
          server: server,
          active_count: server_active_count,
          total_count: server_total_count,
          max_delay: server_max_delay,
          avg_delay: server_avg_delay,
          error_count: server_error_count,
          success_count: server_success_count,
          rate_limits: active_rate_limits.sort_by { |rl| -rl.current_delay }
        }
      end

      next if org_rate_limits.empty?

      # Calculate organization-level average delay
      org_avg_delay = org_total_active.positive? ? (org_rate_limits.sum { |s| s[:avg_delay] * s[:active_count] } / org_total_active.to_f).round : 0

      data << {
        organization: organization,
        total_active: org_total_active,
        total_rate_limits: org_total_rate_limits,
        max_delay: org_max_delay,
        avg_delay: org_avg_delay,
        total_errors: org_total_errors,
        total_successes: org_total_successes,
        servers: org_rate_limits
      }
    end

    data
  end

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
