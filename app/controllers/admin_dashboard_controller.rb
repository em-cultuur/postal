# frozen_string_literal: true

class AdminDashboardController < ApplicationController

  before_action :admin_required

  def index
    # Load all organizations with their servers
    @organizations = Organization.present
                                 .includes(:servers)
                                 .order(:name)
                                 .to_a

    # Calculate system-wide totals
    calculate_system_totals
  end

  private

  def calculate_system_totals
    @total_held_messages = 0
    @total_queued_messages = 0
    @total_bytes_used = 0
    @total_bounces = 0.0
    @total_outgoing = 0.0
    @total_incoming_60min = 0
    @total_outgoing_60min = 0
    @total_messages_per_minute = 0.0
    @server_count = 0

    # Iterate through all organizations and their servers
    @organizations.each do |organization|
      organization.servers.present.each do |server|
        next unless server.message_db

        @server_count += 1

        # Sum up held messages
        @total_held_messages += server.held_messages

        # Sum up queued messages
        @total_queued_messages += server.queue_size

        # Sum up bytes used
        @total_bytes_used += server.message_db.total_size

        # For bounce rate, we need to track totals separately
        time = Time.now.utc
        server.message_db.statistics.get(:daily, [:outgoing, :bounces], time, 30).each do |_, stat|
          @total_outgoing += stat[:outgoing]
          @total_bounces += stat[:bounces]
        end

        # Sum up 60-minute throughput stats
        throughput = server.throughput_stats
        @total_incoming_60min += throughput[:incoming]
        @total_outgoing_60min += throughput[:outgoing]

        # Sum up message rate
        @total_messages_per_minute += server.message_rate
      end
    end

    # Calculate system-wide bounce rate
    @total_bounce_rate = @total_outgoing.zero? ? 0 : (@total_bounces / @total_outgoing) * 100
  end

end
