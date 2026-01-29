# frozen_string_literal: true

class IPAddressesController < ApplicationController

  before_action :admin_required
  before_action :load_ip_pool, except: [:reputation, :pause, :unpause, :advance_warmup, :reset_warmup, :move]
  before_action :load_ip_address_from_pool, only: [:new, :create, :update, :destroy, :edit]
  before_action :load_ip_address_direct, only: [:reputation, :pause, :unpause, :advance_warmup, :reset_warmup, :move]

  def new
    @ip_address = @ip_pool.ip_addresses.build
  end

  def create
    @ip_address = @ip_pool.ip_addresses.build(safe_params)
    if @ip_address.save
      redirect_to_with_json [:edit, @ip_pool]
    else
      render_form_errors "new", @ip_address
    end
  end

  def update
    if @ip_address.update(safe_params)
      redirect_to_with_json [:edit, @ip_pool]
    else
      render_form_errors "edit", @ip_address
    end
  end

  def destroy
    @ip_address.destroy
    redirect_to_with_json [:edit, @ip_pool]
  end

  # GET /ip_addresses/:id/reputation
  # Show detailed reputation information for an IP
  def reputation
    # Load metrics and stats
    @latest_metrics = @ip_address.ip_reputation_metrics.order(created_at: :desc).first
    @reputation_score = @latest_metrics&.reputation_score
    @blacklist_count = @ip_address.ip_blacklist_records.active.count
    @warming_count = @ip_address.ip_domain_exclusions.warming.count
    @paused_count = @ip_address.ip_domain_exclusions.paused.count

    # Load related data
    @blacklists = @ip_address.ip_blacklist_records.active.includes(:ip_health_actions).order(detected_at: :desc).limit(20)
    @exclusions = @ip_address.ip_domain_exclusions.order(created_at: :desc).limit(20)
    @recent_actions = @ip_address.ip_health_actions.includes(:user, :triggered_by_blacklist).order(created_at: :desc).limit(10)

    respond_to do |format|
      format.html
      format.json { render json: reputation_json }
    end
  end

  # POST /ip_addresses/:id/pause
  # Manually pause an IP for a specific domain
  def pause
    domain = params[:destination_domain]
    reason = params[:reason] || "Manual pause by #{current_user.name}"

    if domain.blank?
      return render json: { error: "destination_domain is required" }, status: :unprocessable_content
    end

    # Check if already paused
    exclusion = @ip_address.ip_domain_exclusions.find_by(destination_domain: domain)

    if exclusion
      exclusion.update!(warmup_stage: 0, reason: reason)
      message = "IP moved back to paused state for #{domain}"
    else
      exclusion = @ip_address.ip_domain_exclusions.create!(
        destination_domain: domain,
        warmup_stage: 0,
        excluded_at: Time.current,
        reason: reason
      )
      message = "IP paused for #{domain}"
    end

    # Log action
    IPHealthAction.create!(
      ip_address: @ip_address,
      action_type: IPHealthAction::PAUSE,
      destination_domain: domain,
      reason: reason,
      user: current_user
    )

    respond_to do |format|
      format.html { redirect_back fallback_location: [:edit, @ip_pool], notice: message }
      format.json { render json: { success: true, message: message, exclusion: exclusion } }
    end
  end

  # POST /ip_addresses/:id/unpause
  # Remove pause and optionally start warmup for a domain
  def unpause
    domain = params[:destination_domain]
    start_warmup = params[:start_warmup].present?

    if domain.blank?
      return render json: { error: "destination_domain is required" }, status: :unprocessable_content
    end

    exclusion = @ip_address.ip_domain_exclusions.find_by(destination_domain: domain)

    if exclusion.nil?
      return render json: { error: "No pause found for this domain" }, status: :not_found
    end

    if start_warmup
      # Move to warmup stage 1
      exclusion.advance_warmup_stage!
      message = "IP unpause started warmup for #{domain}"
    else
      # Remove exclusion entirely
      exclusion.destroy
      message = "IP fully unpaused for #{domain}"
    end

    # Log action
    IPHealthAction.create!(
      ip_address: @ip_address,
      action_type: IPHealthAction::UNPAUSE,
      destination_domain: domain,
      reason: "Manual unpause by #{current_user.name}",
      user: current_user
    )

    respond_to do |format|
      format.html { redirect_back fallback_location: [:edit, @ip_pool], notice: message }
      format.json { render json: { success: true, message: message } }
    end
  end

  # POST /ip_addresses/:id/advance_warmup
  # Manually advance warmup stage for a domain
  def advance_warmup
    domain = params[:destination_domain]

    if domain.blank?
      return render json: { error: "destination_domain is required" }, status: :unprocessable_content
    end

    exclusion = @ip_address.ip_domain_exclusions.find_by(destination_domain: domain)

    if exclusion.nil?
      return render json: { error: "No exclusion found for this domain" }, status: :not_found
    end

    if exclusion.warmup_stage >= 5
      return render json: { error: "Already at maximum warmup stage" }, status: :unprocessable_content
    end

    old_stage = exclusion.warmup_stage
    exclusion.advance_warmup_stage!

    # Log action
    IPHealthAction.create!(
      ip_address: @ip_address,
      action_type: IPHealthAction::WARMUP_STAGE_ADVANCE,
      destination_domain: domain,
      reason: "Manual advancement by #{current_user.name}: stage #{old_stage} → #{exclusion.warmup_stage}",
      previous_priority: IPDomainExclusion::WARMUP_STAGES[old_stage][:priority],
      new_priority: IPDomainExclusion::WARMUP_STAGES[exclusion.warmup_stage][:priority],
      user: current_user
    )

    message = "Warmup advanced to stage #{exclusion.warmup_stage} for #{domain}"

    respond_to do |format|
      format.html { redirect_back fallback_location: [:edit, @ip_pool], notice: message }
      format.json { render json: { success: true, message: message, stage: exclusion.warmup_stage } }
    end
  end

  # POST /ip_addresses/:id/reset_warmup
  # Reset warmup to stage 0 for a domain
  def reset_warmup
    domain = params[:destination_domain]
    reason = params[:reason] || "Manual reset by #{current_user.name}"

    if domain.blank?
      return render json: { error: "destination_domain is required" }, status: :unprocessable_content
    end

    exclusion = @ip_address.ip_domain_exclusions.find_by(destination_domain: domain)

    if exclusion.nil?
      return render json: { error: "No exclusion found for this domain" }, status: :not_found
    end

    old_stage = exclusion.warmup_stage
    exclusion.update!(warmup_stage: 0, reason: reason)

    # Log action
    IPHealthAction.create!(
      ip_address: @ip_address,
      action_type: IPHealthAction::MANUAL_OVERRIDE,
      destination_domain: domain,
      reason: "Warmup reset by #{current_user.name}: stage #{old_stage} → 0. Reason: #{reason}",
      user: current_user
    )

    message = "Warmup reset to stage 0 for #{domain}"

    respond_to do |format|
      format.html { redirect_back fallback_location: [:edit, @ip_pool], notice: message }
      format.json { render json: { success: true, message: message } }
    end
  end

  # GET /ip_addresses/:id/move
  # POST /ip_addresses/:id/move
  # Move IP address to a different pool
  def move
    @available_pools = IPPool.where.not(id: @ip_address.ip_pool_id).order(:name)

    return unless request.post?

    new_pool_id = params[:new_pool_id]

    if new_pool_id.blank?
      @error = "Please select a destination pool"
      return render :move
    end

    new_pool = IPPool.find_by(id: new_pool_id)

    if new_pool.nil?
      @error = "Invalid pool selected"
      return render :move
    end

    old_pool = @ip_address.ip_pool

    if @ip_address.update(ip_pool_id: new_pool.id)
      message = "IP address #{@ip_address.ipv4} moved from #{old_pool.name} to #{new_pool.name}"
      redirect_to [:edit, new_pool], notice: message
    else
      @error = "Failed to move IP address"
      render :move
    end
  end

  private

  def safe_params
    params.require(:ip_address).permit(:ipv4, :ipv6, :hostname, :priority)
  end

  def reputation_json
    {
      ip_address: {
        id: @ip_address.id,
        ipv4: @ip_address.ipv4,
        ipv6: @ip_address.ipv6,
        hostname: @ip_address.hostname,
        priority: @ip_address.priority,
        pool: @ip_address.ip_pool&.name
      },
      reputation_score: @reputation_score,
      blacklist_count: @blacklist_count,
      warming_count: @warming_count,
      paused_count: @paused_count,
      latest_metrics: @latest_metrics,
      blacklists: @blacklists.map do |bl|
        {
          id: bl.id,
          blacklist: bl.blacklist_source,
          domain: bl.destination_domain,
          status: if bl.resolved?
                    "resolved"
                  else
                    (bl.ignored? ? "ignored" : "active")
                  end,
          detected_at: bl.detected_at,
          resolved_at: bl.resolved_at
        }
      end,
      exclusions: @exclusions.map do |excl|
        {
          id: excl.id,
          domain: excl.destination_domain,
          stage: excl.warmup_stage,
          priority: excl.current_priority,
          created_at: excl.created_at,
          stage_started_at: excl.stage_started_at
        }
      end,
      recent_actions: @recent_actions.map do |action|
        {
          id: action.id,
          action_type: action.action_type,
          domain: action.destination_domain,
          reason: action.reason,
          created_at: action.created_at,
          user: action.user&.name
        }
      end
    }
  end

  def load_ip_pool
    @ip_pool = IPPool.find_by_uuid!(params[:ip_pool_id])
  end

  def load_ip_address_from_pool
    @ip_address = @ip_pool.ip_addresses.find(params[:id]) if params[:id]
  end

  def load_ip_address_direct
    @ip_address = IPAddress.find(params[:id])
    @ip = @ip_address # Alias for views
  end

end
