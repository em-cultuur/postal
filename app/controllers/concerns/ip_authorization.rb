# frozen_string_literal: true

# IP Authorization Concern
# Provides authorization checks for IP address access control
module IPAuthorization

  extend ActiveSupport::Concern

  included do
    # Add authorization check to relevant actions
    before_action :authorize_ip_access!, only: [:resolve, :ignore, :recheck, :remove, :adjust_stage],
                                         if: -> { defined?(@record) || defined?(@exclusion) }
  end

  private

  # Verify that the current user can access/modify this IP address
  # Checks organization ownership through IP pool associations
  def authorize_ip_access!
    ip_address = determine_ip_address
    return true unless ip_address # Skip if no IP to check

    # Super admins can access everything
    return true if current_user.admin? && !Postal::Config.ip_reputation&.enforce_organization_boundaries

    # Check if user's organization has access to this IP's pool
    ip_pool = ip_address.ip_pool
    return handle_authorization_failure unless ip_pool

    # Check if user has access to this IP pool through their organization
    if current_user.organization.present?
      unless can_access_ip_pool?(ip_pool)
        handle_authorization_failure
        return false
      end
    else
      # User without organization can't access IPs
      handle_authorization_failure
      return false
    end

    true
  end

  # Determine which IP address to check based on instance variables
  def determine_ip_address
    return @record.ip_address if defined?(@record) && @record.respond_to?(:ip_address)
    return @exclusion.ip_address if defined?(@exclusion) && @exclusion.respond_to?(:ip_address)
    return @ip_address if defined?(@ip_address)

    nil
  end

  # Check if user can access the given IP pool
  def can_access_ip_pool?(ip_pool)
    # Check if the user's organization has access to this pool
    OrganizationIPPool.exists?(
      organization_id: current_user.organization.id,
      ip_pool_id: ip_pool.id
    )
  end

  # Handle authorization failure
  def handle_authorization_failure
    Rails.logger.warn "[AUTHORIZATION] User #{current_user.id} (#{current_user.email_address}) " \
                      "attempted unauthorized access to IP resource"

    respond_to do |format|
      format.html do
        flash[:alert] = "You don't have permission to access this IP address"
        redirect_to root_path
      end
      format.json do
        render json: { error: "Unauthorized access to IP resource" },
               status: :forbidden
      end
    end
  end

  # Optional: Check if user can access specific IP address directly
  def authorize_specific_ip!(ip_address_id)
    ip_address = IPAddress.find_by(id: ip_address_id)
    return handle_authorization_failure unless ip_address

    @ip_address = ip_address
    authorize_ip_access!
  end

end
