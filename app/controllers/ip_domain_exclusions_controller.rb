# frozen_string_literal: true

# IP Domain Exclusions Management Controller
# Manages paused/warming IPs for specific domains
class IPDomainExclusionsController < ApplicationController

  include IPAuthorization
  include InputSanitization

  before_action :admin_required
  before_action :load_exclusion, only: [:show, :remove, :adjust_stage]

  # GET /ip_domain_exclusions
  # List all domain exclusions with filtering
  def index
    @exclusions = IPDomainExclusion.includes(:ip_address).order(excluded_at: :desc)

    # Apply filters
    @exclusions = @exclusions.where(warmup_stage: params[:stage]) if params[:stage].present?
    @exclusions = @exclusions.where(ip_address_id: params[:ip_address_id]) if params[:ip_address_id].present?
    @exclusions = @exclusions.where(destination_domain: params[:domain]) if params[:domain].present?

    # Filter by warmup status
    case params[:status]
    when "paused"
      @exclusions = @exclusions.paused
    when "warming"
      @exclusions = @exclusions.warming
    when "ready_for_warmup"
      @exclusions = @exclusions.ready_for_warmup
    end

    # Pagination
    @page = (params[:page] || 1).to_i
    @per_page = (params[:per_page] || 50).to_i.clamp(1, 100)
    @total_count = @exclusions.count
    @total_pages = (@total_count.to_f / @per_page).ceil
    @exclusions = @exclusions.limit(@per_page).offset((@page - 1) * @per_page)

    respond_to do |format|
      format.html
      format.json { render json: exclusions_json }
    end
  end

  # GET /ip_domain_exclusions/:id
  # Show detailed information about an exclusion
  def show
    @metrics = IPReputationMetric
               .where(ip_address: @exclusion.ip_address, destination_domain: @exclusion.destination_domain)
               .where("created_at >= ?", 30.days.ago)
               .order(created_at: :desc)

    @health_actions = IPHealthAction
                      .where(ip_address: @exclusion.ip_address, destination_domain: @exclusion.destination_domain)
                      .order(created_at: :desc)
                      .limit(20)

    # Find related blacklist if this exclusion was triggered by one
    @related_blacklist = IPBlacklistRecord
                         .where(ip_address: @exclusion.ip_address, destination_domain: @exclusion.destination_domain)
                         .order(detected_at: :desc)
                         .first

    respond_to do |format|
      format.html
      format.json { render json: exclusion_detail_json }
    end
  end

  # POST /ip_domain_exclusions/:id/remove
  # Remove an exclusion (fully unpause)
  def remove
    # Sanitize reason input
    reason = sanitize_reason(params[:reason], default: "Manual removal by #{current_user.name}")

    @exclusion.destroy

    # Log action
    IPHealthAction.create!(
      ip_address: @exclusion.ip_address,
      action_type: IPHealthAction::UNPAUSE,
      destination_domain: @exclusion.destination_domain,
      reason: reason,
      user: current_user
    )

    message = "Exclusion removed for #{@exclusion.ip_address.ipv4} / #{@exclusion.destination_domain}"

    respond_to do |format|
      format.html { redirect_to ip_domain_exclusions_path, notice: message }
      format.json { render json: { success: true, message: message } }
    end
  rescue ArgumentError => e
    # Handle invalid reason input
    respond_to do |format|
      format.html { redirect_back fallback_location: ip_domain_exclusion_path(@exclusion), alert: e.message }
      format.json { render json: { error: e.message }, status: :unprocessable_content }
    end
  end

  # POST /ip_domain_exclusions/:id/adjust_stage
  # Adjust warmup stage up or down
  def adjust_stage
    # Sanitize and validate direction parameter
    direction = sanitize_direction(params[:direction])

    # Sanitize and validate stage parameter
    new_stage_param = params[:stage]
    new_stage = new_stage_param ? sanitize_integer(new_stage_param, min: 0, max: 5, default: nil) : nil

    if new_stage
      # Set specific stage
      old_stage = @exclusion.warmup_stage
      @exclusion.update!(warmup_stage: new_stage)

      action_reason = "Manual stage adjustment by #{current_user.name}: #{old_stage} → #{new_stage}"
    elsif direction == "up"
      # Advance one stage
      if @exclusion.warmup_stage >= 5
        return render json: { error: "Already at maximum stage" }, status: :unprocessable_content
      end

      old_stage = @exclusion.warmup_stage
      @exclusion.advance_warmup_stage!
      action_reason = "Manual advancement by #{current_user.name}: stage #{old_stage} → #{@exclusion.warmup_stage}"
    elsif direction == "down"
      # Decrease one stage
      if @exclusion.warmup_stage <= 0
        return render json: { error: "Already at minimum stage" }, status: :unprocessable_content
      end

      old_stage = @exclusion.warmup_stage
      new_stage = old_stage - 1
      @exclusion.update!(warmup_stage: new_stage)
      action_reason = "Manual decrease by #{current_user.name}: stage #{old_stage} → #{new_stage}"
    else
      return render json: { error: "Invalid direction or stage parameter" }, status: :unprocessable_content
    end

    # Log action
    IPHealthAction.create!(
      ip_address: @exclusion.ip_address,
      action_type: IPHealthAction::MANUAL_OVERRIDE,
      destination_domain: @exclusion.destination_domain,
      reason: action_reason,
      user: current_user
    )

    message = "Warmup stage adjusted to #{@exclusion.warmup_stage}"

    respond_to do |format|
      format.html { redirect_back fallback_location: ip_domain_exclusion_path(@exclusion), notice: message }
      format.json { render json: { success: true, message: message, stage: @exclusion.warmup_stage } }
    end
  end

  private

  def load_exclusion
    @exclusion = IPDomainExclusion.includes(:ip_address).find(params[:id])
  end

  def exclusions_json
    {
      exclusions: @exclusions.map do |excl|
        {
          id: excl.id,
          ip: excl.ip_address.ipv4,
          domain: excl.destination_domain,
          warmup_stage: excl.warmup_stage,
          stage_priority: IPDomainExclusion::WARMUP_STAGES[excl.warmup_stage][:priority],
          excluded_at: excl.excluded_at,
          excluded_until: excl.excluded_until,
          next_warmup_at: excl.next_warmup_at,
          reason: excl.reason
        }
      end,
      pagination: {
        page: @page,
        per_page: @per_page,
        total: @total,
        total_pages: (@total.to_f / @per_page).ceil
      }
    }
  end

  def exclusion_detail_json
    {
      exclusion: {
        id: @exclusion.id,
        ip_address: {
          id: @exclusion.ip_address.id,
          ipv4: @exclusion.ip_address.ipv4,
          hostname: @exclusion.ip_address.hostname
        },
        destination_domain: @exclusion.destination_domain,
        warmup_stage: @exclusion.warmup_stage,
        stage_info: IPDomainExclusion::WARMUP_STAGES[@exclusion.warmup_stage],
        excluded_at: @exclusion.excluded_at,
        excluded_until: @exclusion.excluded_until,
        next_warmup_at: @exclusion.next_warmup_at,
        reason: @exclusion.reason
      },
      metrics: @metrics.map do |m|
        {
          date: m.period_date,
          reputation_score: m.reputation_score,
          bounce_rate: m.bounce_rate_percentage,
          sent_count: m.sent_count
        }
      end,
      health_actions: @health_actions.map do |action|
        {
          id: action.id,
          action_type: action.action_type,
          reason: action.reason,
          created_at: action.created_at,
          user: action.user&.name
        }
      end
    }
  end

end
