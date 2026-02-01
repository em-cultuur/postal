# frozen_string_literal: true

class AdminBlockedIpsController < ApplicationController

  before_action :admin_required

  def index
    # Get search query
    @query = params[:query]

    # Cleanup expired entries periodically
    SMTPServer::AuthFailureTracker.cleanup_blocked_index if should_cleanup?

    # Get blocked IPs (with search if query present)
    if @query.present?
      @blocked_ips = SMTPServer::AuthFailureTracker.search_blocked(@query)
    else
      @blocked_ips = SMTPServer::AuthFailureTracker.all_blocked
    end

    # Pagination
    @page = (params[:page] || 1).to_i
    @per_page = 50
    @total_blocked = @blocked_ips.size
    @blocked_ips = @blocked_ips.drop((@page - 1) * @per_page).take(@per_page)
    @total_pages = (@total_blocked.to_f / @per_page).ceil
  end

  def unblock
    ip_address = params[:ip]

    if ip_address.blank?
      flash[:error] = "IP address is required"
      redirect_to admin_blocked_ips_path
      return
    end

    if SMTPServer::AuthFailureTracker.unblock(ip_address)
      flash[:notice] = "IP address #{ip_address} has been unblocked successfully"
    else
      flash[:error] = "Failed to unblock IP address #{ip_address}"
    end

    redirect_to admin_blocked_ips_path
  end

  def unblock_all
    blocked_ips = SMTPServer::AuthFailureTracker.all_blocked
    count = 0

    blocked_ips.each do |ip_info|
      if SMTPServer::AuthFailureTracker.unblock(ip_info[:ip_address])
        count += 1
      end
    end

    flash[:notice] = "Successfully unblocked #{count} IP address#{count == 1 ? '' : 'es'}"
    redirect_to admin_blocked_ips_path
  end

  def cleanup
    cleaned = SMTPServer::AuthFailureTracker.cleanup_blocked_index
    flash[:notice] = "Cleaned up #{cleaned} expired entr#{cleaned == 1 ? 'y' : 'ies'}"
    redirect_to admin_blocked_ips_path
  end

  private

  # Cleanup expired entries every 10th request to avoid overhead
  def should_cleanup?
    rand(10).zero?
  end

end
