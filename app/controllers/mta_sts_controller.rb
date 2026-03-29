# frozen_string_literal: true

class MtaStsController < ApplicationController

  layout false
  protect_from_forgery with: :null_session

  skip_before_action :login_required
  skip_before_action :set_timezone

  # GET /.well-known/mta-sts.txt
  # Serves the MTA-STS policy for the requested domain
  def policy
    domain_name = extract_domain_from_host

    Rails.logger.info "MTA-STS policy request - Host: #{request.host}, Extracted domain: #{domain_name}"

    unless domain_name.present?
      Rails.logger.warn "MTA-STS policy request failed - Invalid domain from host: #{request.host}"
      render plain: "Invalid domain", status: :not_found
      return
    end

    # Search for the domain in the database
    # The domain must be verified and have MTA-STS enabled
    # The search is case-insensitive for the domain name
    domain = Domain.verified.where(mta_sts_enabled: true)
                     .where("LOWER(name) = ?", domain_name.downcase)
                     .first

    unless domain
      Rails.logger.warn "MTA-STS policy request failed - Domain not found or not enabled: #{domain_name}"
      render plain: "MTA-STS policy not found", status: :not_found
      return
    end

    policy_content = domain.mta_sts_policy_content

    unless policy_content
      Rails.logger.error "MTA-STS policy request failed - No policy content for domain: #{domain_name}"
      render plain: "MTA-STS policy not configured", status: :not_found
      return
    end

    # Serve the policy as plain text
    response.headers["Content-Type"] = "text/plain; charset=utf-8"
    response.headers["Cache-Control"] = "max-age=#{domain.mta_sts_max_age || 86400}"

    Rails.logger.info "MTA-STS policy served successfully for domain: #{domain_name}"
    render plain: policy_content
  end

  private

  def extract_domain_from_host
    host = request.host

    # Removes the mta-sts. prefix if present
    # e.g.: mta-sts.example.com -> example.com
    if host.start_with?("mta-sts.")
      host.sub(/\Amta-sts\./, "")
    else
      host
    end
  end

end

