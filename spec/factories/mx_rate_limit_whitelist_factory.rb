# frozen_string_literal: true

# == Schema Information
#
# Table name: mx_rate_limit_whitelists
#
#  id                                                        :integer          not null, primary key
#  description(Why this domain is whitelisted)               :text(65535)
#  mx_domain(Whitelisted MX domain (e.g., mail.example.com)) :string(255)      not null
#  pattern_type(exact, prefix, or regex)                     :string(255)      default("exact"), not null
#  created_at                                                :datetime         not null
#  updated_at                                                :datetime         not null
#  created_by_id(User who created the whitelist entry)       :integer
#  server_id                                                 :integer          not null
#
# Indexes
#
#  fk_rails_680cf527f5               (created_by_id)
#  index_whitelist_on_server         (server_id)
#  index_whitelist_on_server_and_mx  (server_id,mx_domain) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (created_by_id => users.id)
#  fk_rails_...  (server_id => servers.id)
#
FactoryBot.define do
  factory :mx_rate_limit_whitelist do
    server
    mx_domain { "mail.example.com" }
    pattern_type { "exact" }
    description { "Important email provider" }
    created_by { create(:user) }
  end
end
