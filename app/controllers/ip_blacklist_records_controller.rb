# frozen_string_literal: true

# IP Blacklist Records Management Controller
# Allows admins to view, resolve, ignore, and recheck blacklist records
class IPBlacklistRecordsController < ApplicationController

  include IPAuthorization
  include InputSanitization
  include RateLimiting

  before_action :admin_required
  before_action :load_record, only: [:show, :resolve, :ignore, :recheck, :retry_now]
  before_action :rate_limit_recheck, only: [:recheck]
  before_action :rate_limit_retry, only: [:retry_now]

  # GET /ip_blacklist_records
  # List all blacklist records with filtering
  def index
    @records = IPBlacklistRecord.includes(:ip_address).order(created_at: :desc)

    # Apply filters
    @records = @records.where(status: params[:status]) if params[:status].present?
    @records = @records.where(ip_address_id: params[:ip_address_id]) if params[:ip_address_id].present?
    @records = @records.where(blacklist_source: params[:blacklist]) if params[:blacklist].present?
    @records = @records.where(destination_domain: params[:domain]) if params[:domain].present?

    # Pagination
    @page = (params[:page] || 1).to_i
    @per_page = (params[:per_page] || 50).to_i.clamp(1, 100)
    @total_count = @records.count
    @total_pages = (@total_count.to_f / @per_page).ceil
    @records = @records.limit(@per_page).offset((@page - 1) * @per_page)

    # Load data for filters
    @ip_addresses = IPAddress.all

    respond_to do |format|
      format.html
      format.json { render json: records_json }
    end
  end

  # GET /ip_blacklist_records/:id
  # Show detailed information about a blacklist record
  def show
    @related_records = IPBlacklistRecord
                       .where(ip_address: @record.ip_address)
                       .where.not(id: @record.id)
                       .order(created_at: :desc)
                       .limit(10)

    @health_actions = @record.ip_address.ip_health_actions
                             .where("created_at >= ?", @record.created_at)
                             .order(created_at: :desc)
                             .limit(20)

    respond_to do |format|
      format.html
      format.json { render json: record_detail_json }
    end
  end

  # POST /ip_blacklist_records/:id/resolve
  # Mark a blacklist as resolved and trigger recovery
  def resolve
    if @record.resolved?
      return render json: { error: "Already resolved" }, status: :unprocessable_content
    end

    @record.mark_resolved!

    # Trigger warmup if configured and domain-specific
    if @record.destination_domain.present? && Postal::Config.ip_reputation&.auto_warmup_on_delist != false
      IPBlacklist::WarmupManager.start_warmup(
        @record.ip_address,
        @record.destination_domain,
        reason: "Auto-warmup after delisting from #{@record.blacklist_source}"
      )
    end

    message = "Blacklist record marked as resolved"

    respond_to do |format|
      format.html { redirect_back fallback_location: ip_blacklist_records_path, notice: message }
      format.json { render json: { success: true, message: message, record: @record } }
    end
  end

  # POST /ip_blacklist_records/:id/ignore
  # Mark a blacklist as ignored (false positive)
  def ignore
    # Sanitize reason input
    reason = sanitize_reason(params[:reason], default: "Ignored by #{current_user.name}")

    @record.update!(
      status: "ignored",
      resolved_at: Time.current
    )

    # Log action
    IPHealthAction.create!(
      ip_address: @record.ip_address,
      action_type: IPHealthAction::MONITOR,
      destination_domain: @record.destination_domain,
      reason: "Blacklist ignored: #{reason}",
      triggered_by_blacklist: @record,
      user: current_user
    )

    message = "Blacklist record marked as ignored"

    respond_to do |format|
      format.html { redirect_back fallback_location: ip_blacklist_records_path, notice: message }
      format.json { render json: { success: true, message: message } }
    end
  rescue ArgumentError => e
    # Handle invalid reason input
    respond_to do |format|
      format.html { redirect_back fallback_location: ip_blacklist_records_path, alert: e.message }
      format.json { render json: { error: e.message }, status: :unprocessable_content }
    end
  end

  # POST /ip_blacklist_records/:id/recheck
  # Manually trigger a recheck of this blacklist
  def recheck
    checker = IPBlacklist::Checker.new(@record.ip_address)

    # Perform the recheck (this updates the record internally and returns result)
    result = checker.recheck_specific_blacklist(@record)

    # Handle delisting - mark as resolved if no longer listed
    if !result[:listed] && @record.status == IPBlacklistRecord::ACTIVE
      @record.mark_resolved!
      message = "Confirmed delisted from #{@record.blacklist_source}"
    elsif result[:listed]
      message = "Still blacklisted on #{@record.blacklist_source}"
    else
      message = "Recheck completed for #{@record.blacklist_source}"
    end

    respond_to do |format|
      format.html { redirect_back fallback_location: ip_blacklist_record_path(@record), notice: message }
      format.json { render json: { success: true, message: message, listed: result[:listed] } }
    end
  rescue StandardError => e
    # Log detailed error for debugging
    error_id = SecureRandom.uuid
    Rails.logger.error "[BLACKLIST RECHECK] Error ID: #{error_id}"
    Rails.logger.error "[BLACKLIST RECHECK] Record ID: #{@record.id}, User: #{current_user.id}"
    Rails.logger.error "[BLACKLIST RECHECK] #{e.class}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    # Return generic error message to user
    error_message = "Recheck failed. Please try again later. (Error ID: #{error_id})"

    respond_to do |format|
      format.html { redirect_back fallback_location: ip_blacklist_record_path(@record), alert: error_message }
      format.json { render json: { error: error_message, error_id: error_id }, status: :unprocessable_content }
    end
  end

  # POST /ip_blacklist_records/:id/retry_now
  # Manually trigger an immediate retry test for SMTP-detected blacklists
  def retry_now
    # Verify this is an SMTP-detected blacklist
    unless @record.detected_via_smtp?
      message = "Retry is only available for SMTP-detected blacklists"
      return respond_to do |format|
        format.html { redirect_back fallback_location: ip_blacklist_record_path(@record), alert: message }
        format.json { render json: { error: message }, status: :unprocessable_content }
      end
    end

    # Verify record is still active
    unless @record.active?
      message = "Cannot retry: blacklist record is already #{@record.status}"
      return respond_to do |format|
        format.html { redirect_back fallback_location: ip_blacklist_record_path(@record), alert: message }
        format.json { render json: { error: message }, status: :unprocessable_content }
      end
    end

    # Log manual retry trigger
    Rails.logger.info "[BLACKLIST RETRY] Manual retry triggered by #{current_user.name} for record #{@record.id} (IP #{@record.ip_address.ipv4}, domain #{@record.destination_domain})"

    # Perform retry
    begin
      retry_service = IPBlacklist::RetryService.new(@record)
      result = retry_service.perform_retry

      case result
      when :success
        message = "✓ Retry successful! IP #{@record.ip_address.ipv4} is no longer blacklisted for #{@record.destination_domain}. Warmup process started."
        notice_type = :notice
      when :failed
        message = "✗ Retry failed: IP #{@record.ip_address.ipv4} is still blacklisted for #{@record.destination_domain}. Next automatic retry scheduled for #{@record.next_retry_at&.strftime('%Y-%m-%d %H:%M')}. Reason: #{retry_service.error_message}"
        notice_type = :alert
      when :error
        message = "✗ Retry error: #{retry_service.error_message}. Next automatic retry scheduled for #{@record.next_retry_at&.strftime('%Y-%m-%d %H:%M')}."
        notice_type = :alert
      end

      respond_to do |format|
        format.html { redirect_back fallback_location: ip_blacklist_record_path(@record), notice_type => message }
        format.json do
          render json: {
            success: result == :success,
            result: result,
            message: message,
            next_retry_at: @record.next_retry_at,
            record: {
              id: @record.id,
              status: @record.reload.status,
              retry_count: @record.retry_count,
              retry_result: @record.retry_result,
              last_retry_at: @record.last_retry_at
            }
          }
        end
      end
    rescue StandardError => e
      # Log detailed error
      error_id = SecureRandom.uuid
      Rails.logger.error "[BLACKLIST RETRY] Error ID: #{error_id}"
      Rails.logger.error "[BLACKLIST RETRY] Record ID: #{@record.id}, User: #{current_user.name}"
      Rails.logger.error "[BLACKLIST RETRY] #{e.class}: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")

      error_message = "Retry failed due to an error. Please try again later. (Error ID: #{error_id})"

      respond_to do |format|
        format.html { redirect_back fallback_location: ip_blacklist_record_path(@record), alert: error_message }
        format.json { render json: { error: error_message, error_id: error_id }, status: :internal_server_error }
      end
    end
  end

  private

  def load_record
    @record = IPBlacklistRecord.includes(:ip_address).find(params[:id])
  end

  def records_json
    {
      records: @records.map do |record|
        {
          id: record.id,
          ip: record.ip_address.ipv4,
          blacklist: record.blacklist_source,
          domain: record.destination_domain,
          detection_method: record.detection_method,
          status: record.status,
          created_at: record.created_at,
          resolved_at: record.resolved_at,
          last_checked_at: record.last_checked_at
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

  def record_detail_json
    {
      record: {
        id: @record.id,
        ip_address: {
          id: @record.ip_address.id,
          ipv4: @record.ip_address.ipv4,
          hostname: @record.ip_address.hostname
        },
        blacklist_source: @record.blacklist_source,
        destination_domain: @record.destination_domain,
        detection_method: @record.detection_method,
        status: @record.status,
        details: @record.details,
        smtp_response_code: @record.smtp_response_code,
        smtp_response_message: @record.smtp_response_message,
        created_at: @record.created_at,
        resolved_at: @record.resolved_at,
        last_checked_at: @record.last_checked_at,
        resolution_notes: @record.resolution_notes
      },
      related_records: @related_records.map do |r|
        {
          id: r.id,
          blacklist: r.blacklist_source,
          domain: r.destination_domain,
          status: r.status,
          created_at: r.created_at
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
