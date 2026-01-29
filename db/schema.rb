# frozen_string_literal: true

# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.1].define(version: 2026_01_28_120001) do
  create_table "additional_route_endpoints", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.integer "route_id"
    t.string "endpoint_type"
    t.integer "endpoint_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
  end

  create_table "address_endpoints", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.integer "server_id"
    t.string "uuid"
    t.string "address"
    t.datetime "last_used_at", precision: nil
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
  end

  create_table "authie_sessions", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.string "token"
    t.string "browser_id"
    t.integer "user_id"
    t.boolean "active", default: true
    t.text "data"
    t.datetime "expires_at", precision: nil
    t.datetime "login_at", precision: nil
    t.string "login_ip"
    t.datetime "last_activity_at", precision: nil
    t.string "last_activity_ip"
    t.string "last_activity_path"
    t.string "user_agent"
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.string "user_type"
    t.integer "parent_id"
    t.datetime "two_factored_at", precision: nil
    t.string "two_factored_ip"
    t.integer "requests", default: 0
    t.datetime "password_seen_at", precision: nil
    t.string "token_hash"
    t.string "host"
    t.boolean "skip_two_factor", default: false
    t.string "login_ip_country"
    t.string "two_factored_ip_country"
    t.string "last_activity_ip_country"
    t.index ["browser_id"], name: "index_authie_sessions_on_browser_id", length: 8
    t.index ["token"], name: "index_authie_sessions_on_token", length: 8
    t.index ["token_hash"], name: "index_authie_sessions_on_token_hash", length: 8
    t.index ["user_id"], name: "index_authie_sessions_on_user_id"
  end

  create_table "credentials", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.integer "server_id"
    t.string "key"
    t.string "type"
    t.string "name"
    t.text "options"
    t.datetime "last_used_at"
    t.datetime "created_at"
    t.datetime "updated_at"
    t.boolean "hold", default: false
    t.string "uuid"
  end

  create_table "domain_throttles", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.integer "server_id", null: false
    t.string "domain", null: false
    t.datetime "throttled_until", null: false
    t.string "reason"
    t.datetime "created_at", precision: nil
    t.datetime "updated_at", precision: nil
    t.index %w[server_id domain], name: "index_domain_throttles_on_server_id_and_domain", unique: true
    t.index ["throttled_until"], name: "index_domain_throttles_on_throttled_until"
  end

  create_table "domains", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.integer "server_id"
    t.string "uuid"
    t.string "name"
    t.string "verification_token"
    t.string "verification_method"
    t.datetime "verified_at", precision: nil
    t.text "dkim_private_key"
    t.datetime "created_at"
    t.datetime "updated_at"
    t.datetime "dns_checked_at"
    t.string "spf_status"
    t.string "spf_error"
    t.string "dkim_status"
    t.string "dkim_error"
    t.string "mx_status"
    t.string "mx_error"
    t.string "return_path_status"
    t.string "return_path_error"
    t.boolean "outgoing", default: true
    t.boolean "incoming", default: true
    t.string "owner_type"
    t.integer "owner_id"
    t.string "dkim_identifier_string"
    t.boolean "use_for_any"
    t.boolean "mta_sts_enabled", default: false
    t.string "mta_sts_mode", limit: 20, default: "testing"
    t.integer "mta_sts_max_age", default: 86_400
    t.text "mta_sts_mx_patterns"
    t.string "mta_sts_status"
    t.string "mta_sts_error"
    t.boolean "tls_rpt_enabled", default: false
    t.string "tls_rpt_email"
    t.string "tls_rpt_status"
    t.string "tls_rpt_error"
    t.string "dmarc_status"
    t.string "dmarc_error"
    t.index ["server_id"], name: "index_domains_on_server_id"
    t.index ["uuid"], name: "index_domains_on_uuid", length: 8
  end

  create_table "http_endpoints", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.integer "server_id"
    t.string "uuid"
    t.string "name"
    t.string "url"
    t.string "encoding"
    t.string "format"
    t.boolean "strip_replies", default: false
    t.text "error"
    t.datetime "disabled_until"
    t.datetime "last_used_at"
    t.datetime "created_at"
    t.datetime "updated_at"
    t.boolean "include_attachments", default: true
    t.integer "timeout"
  end

  create_table "ip_addresses", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.integer "ip_pool_id"
    t.string "ipv4"
    t.string "ipv6"
    t.datetime "created_at"
    t.datetime "updated_at"
    t.string "hostname"
    t.integer "priority"
  end

  create_table "ip_blacklist_records", id: :integer, charset: "utf8mb4", collation: "utf8mb4_uca1400_ai_ci", force: :cascade do |t|
    t.integer "ip_address_id", null: false
    t.string "destination_domain", null: false
    t.string "blacklist_source", null: false
    t.string "status", default: "active", null: false
    t.text "details"
    t.datetime "detected_at", precision: nil, null: false
    t.datetime "resolved_at", precision: nil
    t.datetime "last_checked_at", precision: nil
    t.integer "check_count", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "detection_method", default: "dnsbl_check"
    t.string "smtp_response_code"
    t.text "smtp_response_message"
    t.integer "smtp_rejection_event_id"
    t.index ["destination_domain"], name: "index_ip_blacklist_records_on_destination_domain"
    t.index ["detection_method"], name: "index_ip_blacklist_records_on_detection_method"
    t.index %w[ip_address_id destination_domain blacklist_source], name: "index_blacklist_on_ip_domain_source", unique: true
    t.index ["ip_address_id"], name: "index_ip_blacklist_records_on_ip_address_id"
    t.index ["smtp_rejection_event_id"], name: "index_ip_blacklist_records_on_smtp_rejection_event_id"
    t.index %w[status last_checked_at], name: "index_ip_blacklist_records_on_status_and_last_checked_at"
  end

  create_table "ip_domain_exclusions", id: :integer, charset: "utf8mb4", collation: "utf8mb4_uca1400_ai_ci", force: :cascade do |t|
    t.integer "ip_address_id", null: false
    t.string "destination_domain", null: false
    t.datetime "excluded_at", precision: nil, null: false
    t.datetime "excluded_until", precision: nil
    t.string "reason"
    t.integer "warmup_stage", default: 0
    t.datetime "next_warmup_at", precision: nil
    t.integer "ip_blacklist_record_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["excluded_until"], name: "index_ip_domain_exclusions_on_excluded_until"
    t.index %w[ip_address_id destination_domain], name: "index_exclusions_on_ip_domain", unique: true
    t.index ["ip_address_id"], name: "index_ip_domain_exclusions_on_ip_address_id"
    t.index ["ip_blacklist_record_id"], name: "fk_rails_9800e8bc75"
    t.index ["next_warmup_at"], name: "index_ip_domain_exclusions_on_next_warmup_at"
  end

  create_table "ip_health_actions", id: :integer, charset: "utf8mb4", collation: "utf8mb4_uca1400_ai_ci", force: :cascade do |t|
    t.integer "ip_address_id", null: false
    t.string "action_type", null: false
    t.string "destination_domain"
    t.text "reason"
    t.integer "previous_priority"
    t.integer "new_priority"
    t.boolean "paused", default: false
    t.integer "triggered_by_blacklist_id"
    t.integer "user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index %w[action_type created_at], name: "index_ip_health_actions_on_action_type_and_created_at"
    t.index %w[ip_address_id created_at], name: "index_ip_health_actions_on_ip_address_id_and_created_at"
    t.index ["ip_address_id"], name: "index_ip_health_actions_on_ip_address_id"
    t.index ["triggered_by_blacklist_id"], name: "fk_rails_ae85b5e5c9"
    t.index ["user_id"], name: "fk_rails_b7e206eaea"
  end

  create_table "ip_pool_rules", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.string "uuid"
    t.string "owner_type"
    t.integer "owner_id"
    t.integer "ip_pool_id"
    t.text "from_text"
    t.text "to_text"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
  end

  create_table "ip_pools", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.string "name"
    t.string "uuid"
    t.datetime "created_at"
    t.datetime "updated_at"
    t.boolean "default", default: false
    t.index ["uuid"], name: "index_ip_pools_on_uuid", length: 8
  end

  create_table "ip_reputation_metrics", id: :integer, charset: "utf8mb4", collation: "utf8mb4_uca1400_ai_ci", force: :cascade do |t|
    t.integer "ip_address_id", null: false
    t.string "destination_domain"
    t.string "sender_domain"
    t.string "period", default: "daily", null: false
    t.date "period_date", null: false
    t.integer "sent_count", default: 0
    t.integer "delivered_count", default: 0
    t.integer "bounced_count", default: 0
    t.integer "soft_fail_count", default: 0
    t.integer "hard_fail_count", default: 0
    t.integer "spam_complaint_count", default: 0
    t.integer "bounce_rate", default: 0
    t.integer "delivery_rate", default: 0
    t.integer "spam_rate", default: 0
    t.integer "reputation_score", default: 100
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "metric_type"
    t.decimal "metric_value", precision: 10, scale: 4
    t.decimal "complaint_rate", precision: 10, scale: 6
    t.decimal "auth_success_rate", precision: 10, scale: 4
    t.integer "trap_hits", default: 0
    t.text "metadata"
    t.index %w[ip_address_id destination_domain period period_date], name: "index_reputation_on_ip_dest_period", unique: true
    t.index %w[ip_address_id metric_type period_date], name: "index_ip_reputation_on_ip_type_date"
    t.index ["ip_address_id"], name: "index_ip_reputation_metrics_on_ip_address_id"
    t.index ["metric_type"], name: "index_ip_reputation_metrics_on_metric_type"
    t.index ["period_date"], name: "index_ip_reputation_metrics_on_period_date"
    t.index ["reputation_score"], name: "index_ip_reputation_metrics_on_reputation_score"
  end

  create_table "mx_domain_cache", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.string "recipient_domain", null: false
    t.string "mx_domain", null: false
    t.text "mx_records"
    t.datetime "resolved_at", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["expires_at"], name: "index_mx_domain_cache_on_expires_at"
    t.index ["recipient_domain"], name: "index_mx_domain_cache_on_recipient_domain", unique: true
  end

  create_table "mx_rate_limit_events", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.integer "server_id", null: false
    t.string "mx_domain", null: false
    t.string "recipient_domain"
    t.string "event_type", null: false
    t.integer "delay_before"
    t.integer "delay_after"
    t.integer "error_count"
    t.integer "success_count"
    t.text "smtp_response"
    t.string "matched_pattern"
    t.integer "queued_message_id"
    t.datetime "created_at", precision: nil
    t.index ["created_at"], name: "index_mx_rate_limit_events_on_created_at"
    t.index ["event_type"], name: "index_mx_rate_limit_events_on_event_type"
    t.index ["queued_message_id"], name: "index_mx_rate_limit_events_on_queued_message_id"
    t.index %w[server_id mx_domain], name: "index_mx_rate_limit_events_on_server_and_mx"
  end

  create_table "mx_rate_limit_patterns", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.string "name", null: false
    t.text "pattern", null: false
    t.boolean "enabled", default: true
    t.integer "priority", default: 0
    t.string "action"
    t.integer "suggested_delay"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["enabled"], name: "index_mx_rate_limit_patterns_on_enabled"
    t.index ["priority"], name: "index_mx_rate_limit_patterns_on_priority"
  end

  create_table "mx_rate_limit_whitelists", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.integer "server_id", null: false
    t.string "mx_domain", null: false, comment: "Whitelisted MX domain (e.g., mail.example.com)"
    t.string "pattern_type", default: "exact", null: false, comment: "exact, prefix, or regex"
    t.text "description", comment: "Why this domain is whitelisted"
    t.integer "created_by_id", comment: "User who created the whitelist entry"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["created_by_id"], name: "fk_rails_680cf527f5"
    t.index %w[server_id mx_domain], name: "index_whitelist_on_server_and_mx", unique: true
    t.index ["server_id"], name: "index_whitelist_on_server"
  end

  create_table "mx_rate_limits", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.integer "server_id", null: false
    t.string "mx_domain", null: false
    t.integer "current_delay", default: 0
    t.integer "error_count", default: 0
    t.integer "success_count", default: 0
    t.datetime "last_error_at"
    t.datetime "last_success_at"
    t.string "last_error_message"
    t.integer "max_attempts", default: 10
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.boolean "whitelisted", default: false, comment: "Skip rate limiting for this MX domain"
    t.index ["current_delay"], name: "index_mx_rate_limits_on_current_delay"
    t.index ["last_error_at"], name: "index_mx_rate_limits_on_last_error_at"
    t.index %w[server_id mx_domain], name: "index_mx_rate_limits_on_server_and_mx", unique: true
    t.index %w[server_id whitelisted], name: "index_mx_rate_limits_whitelisted"
  end

  create_table "organization_ip_pools", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.integer "organization_id"
    t.integer "ip_pool_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
  end

  create_table "organization_users", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.integer "organization_id"
    t.integer "user_id"
    t.datetime "created_at"
    t.boolean "admin", default: false
    t.boolean "all_servers", default: true
    t.string "user_type"
  end

  create_table "organizations", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.string "uuid"
    t.string "name"
    t.string "permalink"
    t.string "time_zone"
    t.datetime "created_at"
    t.datetime "updated_at"
    t.integer "ip_pool_id"
    t.integer "owner_id"
    t.datetime "deleted_at"
    t.datetime "suspended_at"
    t.string "suspension_reason"
    t.index ["permalink"], name: "index_organizations_on_permalink", length: 8
    t.index ["uuid"], name: "index_organizations_on_uuid", length: 8
  end

  create_table "queued_messages", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.integer "server_id"
    t.integer "message_id"
    t.string "domain"
    t.string "locked_by"
    t.datetime "locked_at"
    t.datetime "retry_after", precision: nil
    t.datetime "created_at"
    t.datetime "updated_at"
    t.integer "ip_address_id"
    t.integer "attempts", default: 0
    t.integer "route_id"
    t.boolean "manual", default: false
    t.string "batch_key"
    t.string "mx_domain"
    t.index ["domain"], name: "index_queued_messages_on_domain", length: 8
    t.index ["message_id"], name: "index_queued_messages_on_message_id"
    t.index ["mx_domain"], name: "index_queued_messages_on_mx_domain"
    t.index ["server_id"], name: "index_queued_messages_on_server_id"
  end

  create_table "routes", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.string "uuid"
    t.integer "server_id"
    t.integer "domain_id"
    t.integer "endpoint_id"
    t.string "endpoint_type"
    t.string "name"
    t.string "spam_mode"
    t.datetime "created_at"
    t.datetime "updated_at"
    t.string "token"
    t.string "mode"
    t.index ["token"], name: "index_routes_on_token", length: 6
  end

  create_table "scheduled_tasks", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.string "name"
    t.datetime "next_run_after", precision: nil
    t.index ["name"], name: "index_scheduled_tasks_on_name", unique: true
  end

  create_table "servers", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.integer "organization_id"
    t.string "uuid"
    t.string "name"
    t.string "mode"
    t.integer "ip_pool_id"
    t.datetime "created_at"
    t.datetime "updated_at"
    t.string "permalink"
    t.integer "send_limit"
    t.datetime "deleted_at"
    t.integer "message_retention_days"
    t.integer "raw_message_retention_days"
    t.integer "raw_message_retention_size"
    t.boolean "allow_sender", default: false
    t.string "token"
    t.datetime "send_limit_approaching_at"
    t.datetime "send_limit_approaching_notified_at"
    t.datetime "send_limit_exceeded_at"
    t.datetime "send_limit_exceeded_notified_at"
    t.decimal "spam_threshold", precision: 8, scale: 2
    t.decimal "spam_failure_threshold", precision: 8, scale: 2
    t.string "postmaster_address"
    t.datetime "suspended_at"
    t.decimal "outbound_spam_threshold", precision: 8, scale: 2
    t.text "domains_not_to_click_track"
    t.string "suspension_reason"
    t.boolean "log_smtp_data", default: false
    t.boolean "privacy_mode", default: false
    t.boolean "truemail_enabled", default: false
    t.integer "priority", limit: 2, default: 0, unsigned: true
    t.index ["organization_id"], name: "index_servers_on_organization_id"
    t.index ["permalink"], name: "index_servers_on_permalink", length: 6
    t.index ["token"], name: "index_servers_on_token", length: 6
    t.index ["uuid"], name: "index_servers_on_uuid", length: 8
  end

  create_table "smtp_endpoints", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.integer "server_id"
    t.string "uuid"
    t.string "name"
    t.string "hostname"
    t.string "ssl_mode"
    t.integer "port"
    t.text "error"
    t.datetime "disabled_until"
    t.datetime "last_used_at"
    t.datetime "created_at"
    t.datetime "updated_at"
  end

  create_table "smtp_rejection_events", id: :integer, charset: "utf8mb4", collation: "utf8mb4_uca1400_ai_ci", force: :cascade do |t|
    t.integer "ip_address_id", null: false
    t.string "destination_domain", null: false
    t.string "smtp_code", null: false
    t.string "bounce_type", null: false
    t.text "smtp_message"
    t.text "parsed_details"
    t.datetime "occurred_at", precision: nil, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index %w[bounce_type occurred_at], name: "index_smtp_rejection_events_on_bounce_type_and_occurred_at"
    t.index ["destination_domain"], name: "index_smtp_rejection_events_on_destination_domain"
    t.index %w[ip_address_id destination_domain occurred_at], name: "index_smtp_events_on_ip_domain_time"
    t.index ["ip_address_id"], name: "index_smtp_rejection_events_on_ip_address_id"
  end

  create_table "statistics", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.bigint "total_messages", default: 0
    t.bigint "total_outgoing", default: 0
    t.bigint "total_incoming", default: 0
  end

  create_table "track_certificates", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.string "domain"
    t.text "certificate"
    t.text "intermediaries"
    t.text "key"
    t.datetime "expires_at", precision: nil
    t.datetime "renew_after", precision: nil
    t.string "verification_path"
    t.string "verification_string"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["domain"], name: "index_track_certificates_on_domain", length: 8
  end

  create_table "track_domains", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.string "uuid"
    t.integer "server_id"
    t.integer "domain_id"
    t.string "name"
    t.datetime "dns_checked_at", precision: nil
    t.string "dns_status"
    t.string "dns_error"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.boolean "ssl_enabled", default: true
    t.boolean "track_clicks", default: true
    t.boolean "track_loads", default: true
    t.text "excluded_click_domains"
  end

  create_table "user_invites", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.string "uuid"
    t.string "email_address"
    t.datetime "expires_at"
    t.datetime "created_at"
    t.datetime "updated_at"
    t.index ["uuid"], name: "index_user_invites_on_uuid", length: 12
  end

  create_table "users", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.string "uuid"
    t.string "first_name"
    t.string "last_name"
    t.string "email_address"
    t.string "password_digest"
    t.string "time_zone"
    t.string "email_verification_token"
    t.datetime "email_verified_at", precision: nil
    t.datetime "created_at"
    t.datetime "updated_at"
    t.string "password_reset_token"
    t.datetime "password_reset_token_valid_until", precision: nil
    t.boolean "admin", default: false
    t.string "oidc_uid"
    t.string "oidc_issuer"
    t.index ["email_address"], name: "index_users_on_email_address", length: 8
    t.index ["uuid"], name: "index_users_on_uuid", length: 8
  end

  create_table "webhook_events", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.integer "webhook_id"
    t.string "event"
    t.datetime "created_at"
    t.index ["webhook_id"], name: "index_webhook_events_on_webhook_id"
  end

  create_table "webhook_requests", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.integer "server_id"
    t.integer "webhook_id"
    t.string "url"
    t.string "event"
    t.string "uuid"
    t.text "payload"
    t.integer "attempts", default: 0
    t.datetime "retry_after"
    t.text "error"
    t.datetime "created_at"
    t.string "locked_by"
    t.datetime "locked_at", precision: nil
    t.index ["locked_by"], name: "index_webhook_requests_on_locked_by"
    t.index ["uuid"], name: "index_webhook_requests_on_uuid"
  end

  create_table "webhooks", id: :integer, charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.integer "server_id"
    t.string "uuid"
    t.string "name"
    t.string "url"
    t.datetime "last_used_at", precision: nil
    t.boolean "all_events", default: false
    t.boolean "enabled", default: true
    t.boolean "sign", default: true
    t.datetime "created_at"
    t.datetime "updated_at"
    t.index ["server_id"], name: "index_webhooks_on_server_id"
  end

  create_table "worker_roles", charset: "utf8mb4", collation: "utf8mb4_general_ci", force: :cascade do |t|
    t.string "role"
    t.string "worker"
    t.datetime "acquired_at", precision: nil
    t.index ["role"], name: "index_worker_roles_on_role", unique: true
  end

  add_foreign_key "ip_blacklist_records", "ip_addresses"
  add_foreign_key "ip_blacklist_records", "smtp_rejection_events"
  add_foreign_key "ip_domain_exclusions", "ip_addresses"
  add_foreign_key "ip_domain_exclusions", "ip_blacklist_records"
  add_foreign_key "ip_health_actions", "ip_addresses"
  add_foreign_key "ip_health_actions", "ip_blacklist_records", column: "triggered_by_blacklist_id"
  add_foreign_key "ip_health_actions", "users"
  add_foreign_key "ip_reputation_metrics", "ip_addresses"
  add_foreign_key "mx_rate_limit_events", "servers"
  add_foreign_key "mx_rate_limit_whitelists", "servers"
  add_foreign_key "mx_rate_limit_whitelists", "users", column: "created_by_id"
  add_foreign_key "mx_rate_limits", "servers"
  add_foreign_key "smtp_rejection_events", "ip_addresses"
end
