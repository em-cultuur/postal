# frozen_string_literal: true

# == Schema Information
#
# Table name: ip_blacklist_records
#
#  id                      :integer          not null, primary key
#  blacklist_source        :string(255)      not null
#  check_count             :integer          default(0)
#  destination_domain      :string(255)      not null
#  details                 :text(65535)
#  detected_at             :datetime         not null
#  detection_method        :string(255)      default("dnsbl_check")
#  last_checked_at         :datetime
#  resolved_at             :datetime
#  smtp_response_code      :string(255)
#  smtp_response_message   :text(65535)
#  status                  :string(255)      default("active"), not null
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  ip_address_id           :integer          not null
#  smtp_rejection_event_id :integer
#
# Indexes
#
#  index_blacklist_on_ip_domain_source                       (ip_address_id,destination_domain,blacklist_source) UNIQUE
#  index_ip_blacklist_records_on_destination_domain          (destination_domain)
#  index_ip_blacklist_records_on_detection_method            (detection_method)
#  index_ip_blacklist_records_on_ip_address_id               (ip_address_id)
#  index_ip_blacklist_records_on_smtp_rejection_event_id     (smtp_rejection_event_id)
#  index_ip_blacklist_records_on_status_and_last_checked_at  (status,last_checked_at)
#
# Foreign Keys
#
#  fk_rails_...  (ip_address_id => ip_addresses.id)
#  fk_rails_...  (smtp_rejection_event_id => smtp_rejection_events.id)
#
require "rails_helper"

RSpec.describe IPBlacklistRecord, type: :model do
  describe "associations" do
    it { should belong_to(:ip_address) }
    it { should have_many(:ip_health_actions).with_foreign_key(:triggered_by_blacklist_id) }
    it { should have_one(:ip_domain_exclusion) }
  end

  describe "validations" do
    subject(:record) { build(:ip_blacklist_record) }

    it { should validate_presence_of(:destination_domain) }
    it { should validate_presence_of(:blacklist_source) }
    it { should validate_presence_of(:detected_at) }
    it { should validate_inclusion_of(:status).in_array(IPBlacklistRecord::STATUSES) }
  end

  describe "scopes" do
    let(:ip_address) { create(:ip_address) }
    let!(:active_record) { create(:ip_blacklist_record, ip_address: ip_address, status: "active", destination_domain: "gmail.com") }
    let!(:resolved_record) { create(:ip_blacklist_record, ip_address: ip_address, status: "resolved", destination_domain: "yahoo.com") }
    let!(:ignored_record) { create(:ip_blacklist_record, ip_address: ip_address, status: "ignored", destination_domain: "outlook.com") }

    describe ".active" do
      it "returns only active records" do
        expect(IPBlacklistRecord.active).to include(active_record)
        expect(IPBlacklistRecord.active).not_to include(resolved_record)
        expect(IPBlacklistRecord.active).not_to include(ignored_record)
      end
    end

    describe ".resolved" do
      it "returns only resolved records" do
        expect(IPBlacklistRecord.resolved).to include(resolved_record)
        expect(IPBlacklistRecord.resolved).not_to include(active_record)
      end
    end

    describe ".for_domain" do
      let!(:gmail_record) { create(:ip_blacklist_record, ip_address: ip_address, destination_domain: "gmail.com", blacklist_source: "spamcop") }
      let!(:yahoo_record) { create(:ip_blacklist_record, ip_address: ip_address, destination_domain: "yahoo.com", blacklist_source: "barracuda") }

      it "filters by destination domain" do
        expect(IPBlacklistRecord.for_domain("gmail.com")).to include(gmail_record)
        expect(IPBlacklistRecord.for_domain("gmail.com")).not_to include(yahoo_record)
      end
    end
  end

  describe "#mark_resolved!" do
    let(:record) { create(:ip_blacklist_record, status: "active") }

    it "updates status to resolved" do
      record.mark_resolved!
      expect(record.status).to eq("resolved")
    end

    it "sets resolved_at timestamp" do
      expect { record.mark_resolved! }.to change { record.resolved_at }.from(nil)
    end
  end

  describe "#parsed_details" do
    let(:record) { create(:ip_blacklist_record, details: '{"reason": "spam", "code": 123}') }

    it "parses JSON details" do
      expect(record.parsed_details).to eq({ "reason" => "spam", "code" => 123 })
    end

    context "with invalid JSON" do
      let(:record) { create(:ip_blacklist_record, details: "invalid json") }

      it "returns empty hash" do
        expect(record.parsed_details).to eq({})
      end
    end
  end

  describe "status predicates" do
    it "returns correct values for active?" do
      record = create(:ip_blacklist_record, status: "active")
      expect(record.active?).to be true
      expect(record.resolved?).to be false
      expect(record.ignored?).to be false
    end
  end
end
