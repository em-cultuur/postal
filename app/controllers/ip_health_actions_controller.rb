# frozen_string_literal: true

# IP Health Actions Controller
# Read-only view of health action audit trail
class IPHealthActionsController < ApplicationController

  before_action :admin_required
  before_action :load_action, only: [:show]

  # GET /ip_health_actions
  # List all health actions with filtering
  def index
    @actions = IPHealthAction.includes(:ip_address, :user).order(created_at: :desc)

    # Apply filters
    @actions = @actions.where(action_type: params[:action_type]) if params[:action_type].present?
    @actions = @actions.where(ip_address_id: params[:ip_address_id]) if params[:ip_address_id].present?
    @actions = @actions.where(destination_domain: params[:domain]) if params[:domain].present?
    @actions = @actions.where(user_id: params[:user_id]) if params[:user_id].present?

    # Date range filter
    if params[:from_date].present?
      @actions = @actions.where("created_at >= ?", Date.parse(params[:from_date]))
    end
    if params[:to_date].present?
      @actions = @actions.where("created_at <= ?", Date.parse(params[:to_date]).end_of_day)
    end

    # Pagination
    @page = (params[:page] || 1).to_i
    @per_page = (params[:per_page] || 50).to_i.clamp(1, 100)
    @total_count = @actions.count
    @total_pages = (@total_count.to_f / @per_page).ceil
    @actions = @actions.limit(@per_page).offset((@page - 1) * @per_page)

    # Load filter data
    @ip_addresses = IPAddress.all
    @users = User.all

    # Summary stats
    @stats = {
      total_count: IPHealthAction.count,
      system_actions: IPHealthAction.where(user_id: nil).count,
      manual_actions: IPHealthAction.where.not(user_id: nil).count,
      last_24h: IPHealthAction.where("created_at >= ?", 24.hours.ago).count
    }

    respond_to do |format|
      format.html
      format.json { render json: actions_json }
    end
  end

  # GET /ip_health_actions/:id
  # Show detailed information about a health action
  def show
    @related_actions = IPHealthAction
                       .where(ip_address: @action.ip_address, destination_domain: @action.destination_domain)
                       .where.not(id: @action.id)
                       .order(created_at: :desc)
                       .limit(10)

    respond_to do |format|
      format.html
      format.json { render json: action_detail_json }
    end
  end

  private

  def load_action
    @action = IPHealthAction.includes(:ip_address, :user, :triggered_by_blacklist).find(params[:id])
  end

  def actions_json
    {
      actions: @actions.map do |action|
        {
          id: action.id,
          ip: action.ip_address.ipv4,
          action_type: action.action_type,
          domain: action.destination_domain,
          reason: action.reason,
          paused: action.paused,
          priority_change: action.new_priority ? "#{action.previous_priority} → #{action.new_priority}" : nil,
          user: action.user&.name,
          created_at: action.created_at
        }
      end,
      stats: @stats,
      pagination: {
        page: @page,
        per_page: @per_page,
        total: @total,
        total_pages: (@total.to_f / @per_page).ceil
      }
    }
  end

  def action_detail_json
    {
      action: {
        id: @action.id,
        ip_address: {
          id: @action.ip_address.id,
          ipv4: @action.ip_address.ipv4,
          hostname: @action.ip_address.hostname
        },
        action_type: @action.action_type,
        destination_domain: @action.destination_domain,
        reason: @action.reason,
        paused: @action.paused,
        previous_priority: @action.previous_priority,
        new_priority: @action.new_priority,
        triggered_by_blacklist: if @action.triggered_by_blacklist_id
                                  {
                                          id: @action.triggered_by_blacklist.id,
                                          source: @action.triggered_by_blacklist.blacklist_source
                                        }
                                end,
        user: if @action.user
                {
                        id: @action.user.id,
                        name: @action.user.name
                      }
              end,
        created_at: @action.created_at
      },
      related_actions: @related_actions.map do |a|
        {
          id: a.id,
          action_type: a.action_type,
          reason: a.reason,
          created_at: a.created_at
        }
      end
    }
  end

end
