# frozen_string_literal: true

# == Schema Information
#
# Table name: domains
#
#  id                     :integer          not null, primary key
#  dkim_error             :string(255)
#  dkim_identifier_string :string(255)
#  dkim_private_key       :text(65535)
#  dkim_status            :string(255)
#  dmarc_error            :string(255)
#  dmarc_status           :string(255)
#  dns_checked_at         :datetime
#  incoming               :boolean          default(TRUE)
#  mta_sts_enabled        :boolean          default(FALSE)
#  mta_sts_error          :string(255)
#  mta_sts_max_age        :integer          default(86400)
#  mta_sts_mode           :string(20)       default("testing")
#  mta_sts_mx_patterns    :text(65535)
#  mta_sts_status         :string(255)
#  mx_error               :string(255)
#  mx_status              :string(255)
#  name                   :string(255)
#  outgoing               :boolean          default(TRUE)
#  owner_type             :string(255)
#  return_path_error      :string(255)
#  return_path_status     :string(255)
#  spf_error              :string(255)
#  spf_status             :string(255)
#  tls_rpt_email          :string(255)
#  tls_rpt_enabled        :boolean          default(FALSE)
#  tls_rpt_error          :string(255)
#  tls_rpt_status         :string(255)
#  use_for_any            :boolean
#  uuid                   :string(255)
#  verification_method    :string(255)
#  verification_token     :string(255)
#  verified_at            :datetime
#  created_at             :datetime
#  updated_at             :datetime
#  owner_id               :integer
#  server_id              :integer
#
# Indexes
#
#  index_domains_on_server_id  (server_id)
#  index_domains_on_uuid       (uuid)
#

require "resolv"

class Domain < ApplicationRecord

  include HasUUID

  include HasDNSChecks

  VERIFICATION_EMAIL_ALIASES = %w[webmaster postmaster admin administrator hostmaster].freeze
  VERIFICATION_METHODS = %w[DNS Email].freeze
  MTA_STS_MODES = %w[none testing enforce].freeze

  belongs_to :server, optional: true
  belongs_to :owner, optional: true, polymorphic: true
  has_many :routes, dependent: :destroy
  has_many :track_domains, dependent: :destroy

  validates :name, presence: true, format: { with: /\A[a-z0-9\-.]*\z/ }, uniqueness: { case_sensitive: false, scope: [:owner_type, :owner_id], message: "is already added" }
  validates :verification_method, inclusion: { in: VERIFICATION_METHODS }
  validates :mta_sts_mode, inclusion: { in: MTA_STS_MODES }, allow_nil: true
  validates :mta_sts_max_age, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :tls_rpt_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true

  random_string :dkim_identifier_string, type: :chars, length: 6, unique: true, upper_letters_only: true

  before_create :generate_dkim_key

  scope :verified, -> { where.not(verified_at: nil) }

  before_save :update_verification_token_on_method_change

  def verified?
    verified_at.present?
  end

  def mark_as_verified
    return false if verified?

    self.verified_at = Time.now
    save!
  end

  def parent_domains
    parts = name.split(".")
    parts[0, parts.size - 1].each_with_index.map do |_, i|
      parts[i..].join(".")
    end
  end

  def generate_dkim_key
    self.dkim_private_key = OpenSSL::PKey::RSA.new(Postal::Config.postal.default_dkim_key_size).to_s
  end

  def dkim_key
    return nil unless dkim_private_key

    @dkim_key ||= OpenSSL::PKey::RSA.new(dkim_private_key)
  end

  def to_param
    uuid
  end

  def verification_email_addresses
    parent_domains.map do |domain|
      VERIFICATION_EMAIL_ALIASES.map do |a|
        "#{a}@#{domain}"
      end
    end.flatten
  end

  def spf_record
    "v=spf1 a mx include:#{Postal::Config.dns.spf_include} ~all"
  end

  def dkim_record
    return if dkim_key.nil?

    public_key = dkim_key.public_key.to_s.gsub(/-+[A-Z ]+-+\n/, "").gsub(/\n/, "")
    "v=DKIM1; t=s; h=sha256; p=#{public_key};"
  end

  def dkim_identifier
    return nil unless dkim_identifier_string

    Postal::Config.dns.dkim_identifier + "-#{dkim_identifier_string}"
  end

  def dkim_record_name
    identifier = dkim_identifier
    return if identifier.nil?

    "#{identifier}._domainkey"
  end

  def return_path_domain
    "#{Postal::Config.dns.custom_return_path_prefix}.#{name}"
  end

  def dmarc_record
    Postal::Config.dns.dmarc_preferred_dns_entry
  end

  def dmarc_record_name
    "_dmarc.#{name}"
  end

  # Returns a DNSResolver instance that can be used to perform DNS lookups needed for
  # the verification and DNS checking for this domain.
  #
  # @return [DNSResolver]
  def resolver
    return DNSResolver.local if Postal::Config.postal.use_local_ns_for_domain_verification?

    @resolver ||= DNSResolver.for_domain(name)
  end

  def dns_verification_string
    "#{Postal::Config.dns.domain_verify_prefix} #{verification_token}"
  end

  def verify_with_dns
    return false unless verification_method == "DNS"

    result = resolver.txt(name)

    if result.include?(dns_verification_string)
      self.verified_at = Time.now
      return save
    end

    false
  end

  # MTA-STS methods

  def mta_sts_record_name
    "_mta-sts.#{name}"
  end

  def mta_sts_record_value
    "v=STSv1; id=#{mta_sts_policy_id};"
  end

  def mta_sts_policy_id
    # Genera un ID univoco basato sulla configurazione corrente
    # Cambia ogni volta che la policy viene modificata
    data = "#{mta_sts_mode}:#{mta_sts_max_age}:#{mta_sts_mx_patterns}:#{updated_at.to_i}"
    Digest::SHA256.hexdigest(data)[0..19]
  end

  def mta_sts_policy_content
    return nil unless mta_sts_enabled

    mx_list = if mta_sts_mx_patterns.present?
                mta_sts_mx_patterns.split("\n").map(&:strip).reject(&:blank?)
              else
                default_mta_sts_mx_patterns
              end

    policy = []
    policy << "version: STSv1"
    policy << "mode: #{mta_sts_mode}"
    mx_list.each { |mx| policy << "mx: #{mx}" }
    policy << "max_age: #{mta_sts_max_age}"
    policy.join("\n") + "\n"
  end

  def default_mta_sts_mx_patterns
    # Usa gli MX records configurati in Postal
    Postal::Config.dns.mx_records.map { |mx| "*.#{mx}" }
  end

  def mta_sts_policy_url
    "https://mta-sts.#{name}/.well-known/mta-sts.txt"
  end

  # TLS-RPT methods

  def tls_rpt_record_name
    "_smtp._tls.#{name}"
  end

  def tls_rpt_record_value
    return nil unless tls_rpt_enabled

    email = tls_rpt_email.presence || default_tls_rpt_email
    "v=TLSRPTv1; rua=mailto:#{email}"
  end

  def default_tls_rpt_email
    "tls-reports@#{name}"
  end

  private

  def update_verification_token_on_method_change
    return unless verification_method_changed?

    if verification_method == "DNS"
      self.verification_token = SecureRandom.alphanumeric(32)
    elsif verification_method == "Email"
      self.verification_token = rand(999_999).to_s.ljust(6, "0")
    else
      self.verification_token = nil
    end
  end

end
