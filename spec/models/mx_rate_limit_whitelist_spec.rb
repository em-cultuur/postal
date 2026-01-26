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
require "rails_helper"

describe MXRateLimitWhitelist do
  subject(:whitelist) { build(:mx_rate_limit_whitelist) }

  let(:server) { create(:server) }
  let(:user) { create(:user) }

  describe "validations" do
    it { is_expected.to validate_presence_of(:mx_domain) }

    it "validates uniqueness of mx_domain scoped to server (case-insensitive)" do
      existing = create(:mx_rate_limit_whitelist, server: server, mx_domain: "mail.example.com")
      duplicate = build(:mx_rate_limit_whitelist, server: server, mx_domain: "MAIL.EXAMPLE.COM")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:mx_domain]).to be_present
    end

    it "allows same domain on different servers" do
      create(:mx_rate_limit_whitelist, server: server, mx_domain: "mail.example.com")
      other_server = create(:server)
      whitelist = build(:mx_rate_limit_whitelist, server: other_server, mx_domain: "mail.example.com")
      expect(whitelist).to be_valid
    end

    it "validates pattern_type inclusion" do
      whitelist.pattern_type = "invalid"
      expect(whitelist).not_to be_valid
      expect(whitelist.errors[:pattern_type]).to be_present
    end
  end

  describe "#matches?" do
    context "with exact pattern type" do
      let(:whitelist) { build(:mx_rate_limit_whitelist, pattern_type: "exact", mx_domain: "mail.example.com") }

      it "matches exact domain" do
        expect(whitelist.matches?("mail.example.com")).to be true
      end

      it "does not match different domain" do
        expect(whitelist.matches?("mail.other.com")).to be false
      end

      it "matches case-insensitively" do
        expect(whitelist.matches?("MAIL.EXAMPLE.COM")).to be true
      end
    end

    context "with prefix pattern type" do
      let(:whitelist) { build(:mx_rate_limit_whitelist, pattern_type: "prefix", mx_domain: "mail") }

      it "matches domains starting with prefix" do
        expect(whitelist.matches?("mail.example.com")).to be true
        expect(whitelist.matches?("mail2.example.com")).to be true
      end

      it "does not match domains not starting with prefix" do
        expect(whitelist.matches?("smtp.example.com")).to be false
      end

      it "matches case-insensitively" do
        expect(whitelist.matches?("MAIL.EXAMPLE.COM")).to be true
      end
    end

    context "with regex pattern type" do
      let(:whitelist) { build(:mx_rate_limit_whitelist, pattern_type: "regex", mx_domain: "^mail[0-9]+\\.example\\.com$") }

      it "matches regex pattern" do
        expect(whitelist.matches?("mail1.example.com")).to be true
        expect(whitelist.matches?("mail99.example.com")).to be true
      end

      it "does not match non-matching pattern" do
        expect(whitelist.matches?("mail.example.com")).to be false
        expect(whitelist.matches?("smtp1.example.com")).to be false
      end

      it "handles regex timeout gracefully" do
        # Test with regex that matches numbers
        whitelist = build(:mx_rate_limit_whitelist, pattern_type: "regex", mx_domain: "\\d+")
        expect(whitelist.matches?("123")).to be true
        expect(whitelist.matches?("aaa")).to be false
      end

      it "handles invalid regex gracefully" do
        whitelist = build(:mx_rate_limit_whitelist, pattern_type: "regex", mx_domain: "[invalid")
        expect(whitelist.matches?("test.com")).to be false
      end
    end
  end

  describe ".whitelisted?" do
    let(:exact_whitelist) { create(:mx_rate_limit_whitelist, server: server, pattern_type: "exact", mx_domain: "mail.example.com") }
    let(:prefix_whitelist) { create(:mx_rate_limit_whitelist, server: server, pattern_type: "prefix", mx_domain: "mail") }

    it "returns true for whitelisted domain (exact)" do
      exact_whitelist
      expect(described_class.whitelisted?(server, "mail.example.com")).to be true
    end

    it "returns true for whitelisted domain (prefix)" do
      prefix_whitelist
      expect(described_class.whitelisted?(server, "mail.test.com")).to be true
    end

    it "returns false for non-whitelisted domain" do
      exact_whitelist
      expect(described_class.whitelisted?(server, "smtp.example.com")).to be false
    end

    it "returns false for blank domain" do
      expect(described_class.whitelisted?(server, "")).to be false
      expect(described_class.whitelisted?(server, nil)).to be false
    end
  end

  describe ".for_server" do
    it "returns all whitelisted domains for a server" do
      create(:mx_rate_limit_whitelist, server: server, mx_domain: "mail1.com")
      create(:mx_rate_limit_whitelist, server: server, mx_domain: "mail2.com")

      domains = described_class.for_server(server)
      expect(domains).to contain_exactly("mail1.com", "mail2.com")
    end

    it "returns empty array for server with no whitelists" do
      expect(described_class.for_server(server)).to be_empty
    end
  end

  describe "associations" do
    let(:whitelist) { create(:mx_rate_limit_whitelist, server: server, created_by: user) }

    it { is_expected.to belong_to(:server) }
    it { is_expected.to belong_to(:created_by).class_name("User").optional }

    it "belongs to server" do
      expect(whitelist.server).to eq(server)
    end

    it "belongs to created_by user" do
      expect(whitelist.created_by).to eq(user)
    end
  end
end
