# frozen_string_literal: true

# == Schema Information
#
# Table name: ip_domain_exclusions
#
#  id                     :integer          not null, primary key
#  destination_domain     :string(255)      not null
#  excluded_at            :datetime         not null
#  excluded_until         :datetime
#  next_warmup_at         :datetime
#  reason                 :string(255)
#  warmup_stage           :integer          default(0)
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  ip_address_id          :integer          not null
#  ip_blacklist_record_id :integer
#
# Indexes
#
#  fk_rails_9800e8bc75                           (ip_blacklist_record_id)
#  index_exclusions_on_ip_domain                 (ip_address_id,destination_domain) UNIQUE
#  index_ip_domain_exclusions_on_excluded_until  (excluded_until)
#  index_ip_domain_exclusions_on_ip_address_id   (ip_address_id)
#  index_ip_domain_exclusions_on_next_warmup_at  (next_warmup_at)
#
# Foreign Keys
#
#  fk_rails_...  (ip_address_id => ip_addresses.id)
#  fk_rails_...  (ip_blacklist_record_id => ip_blacklist_records.id)
#
require "rails_helper"

RSpec.describe IPDomainExclusion, type: :model do
  describe "associations" do
    it { should belong_to(:ip_address) }
    it { should belong_to(:ip_blacklist_record).optional }
  end

  describe "validations" do
    it { should validate_presence_of(:destination_domain) }
    it { should validate_presence_of(:excluded_at) }
  end

  describe "warmup stages" do
    let(:exclusion) { create(:ip_domain_exclusion, warmup_stage: 0) }

    describe "#advance_warmup_stage!" do
      it "progresses to next stage" do
        expect { exclusion.advance_warmup_stage! }.to change { exclusion.warmup_stage }.from(0).to(1)
      end

      it "sets next_warmup_at based on stage duration" do
        exclusion.advance_warmup_stage!
        expect(exclusion.next_warmup_at).to be_within(1.minute).of(2.days.from_now)
      end

      it "creates a health action record" do
        expect { exclusion.advance_warmup_stage! }.to change { IPHealthAction.count }.by(1)
      end

      it "destroys exclusion when reaching stage 5" do
        exclusion.update(warmup_stage: 4)
        expect { exclusion.advance_warmup_stage! }.to change { IPDomainExclusion.count }.by(-1)
      end
    end

    describe "#current_priority" do
      it "returns correct priority for each stage" do
        expect(create(:ip_domain_exclusion, warmup_stage: 0).current_priority).to eq(0)
        expect(create(:ip_domain_exclusion, warmup_stage: 1).current_priority).to eq(20)
        expect(create(:ip_domain_exclusion, warmup_stage: 2).current_priority).to eq(40)
        expect(create(:ip_domain_exclusion, warmup_stage: 3).current_priority).to eq(60)
        expect(create(:ip_domain_exclusion, warmup_stage: 4).current_priority).to eq(80)
      end
    end
  end

  describe "scopes" do
    describe ".active" do
      let!(:active_exclusion) { create(:ip_domain_exclusion, excluded_until: nil) }
      let!(:future_exclusion) { create(:ip_domain_exclusion, excluded_until: 1.day.from_now) }
      let!(:expired_exclusion) { create(:ip_domain_exclusion, excluded_until: 1.day.ago) }

      it "returns active and future exclusions" do
        expect(IPDomainExclusion.active).to include(active_exclusion, future_exclusion)
        expect(IPDomainExclusion.active).not_to include(expired_exclusion)
      end
    end

    describe ".ready_for_warmup" do
      let!(:ready_exclusion) { create(:ip_domain_exclusion, next_warmup_at: 1.hour.ago, warmup_stage: 1) }
      let!(:not_ready_exclusion) { create(:ip_domain_exclusion, next_warmup_at: 1.hour.from_now, warmup_stage: 1) }

      it "returns exclusions ready for warmup" do
        expect(IPDomainExclusion.ready_for_warmup).to include(ready_exclusion)
        expect(IPDomainExclusion.ready_for_warmup).not_to include(not_ready_exclusion)
      end
    end
  end

  describe "predicates" do
    it "correctly identifies paused state" do
      exclusion = create(:ip_domain_exclusion, warmup_stage: 0)
      expect(exclusion.paused?).to be true
      expect(exclusion.warming?).to be false
    end

    it "correctly identifies warming state" do
      exclusion = create(:ip_domain_exclusion, warmup_stage: 2)
      expect(exclusion.paused?).to be false
      expect(exclusion.warming?).to be true
      expect(exclusion.fully_recovered?).to be false
    end
  end

  describe "#warmup_progress_percentage" do
    it "returns 0 for paused" do
      exclusion = create(:ip_domain_exclusion, warmup_stage: 0)
      expect(exclusion.warmup_progress_percentage).to eq(0)
    end

    it "returns 100 for fully recovered" do
      exclusion = create(:ip_domain_exclusion, warmup_stage: 5)
      expect(exclusion.warmup_progress_percentage).to eq(100)
    end

    it "returns correct percentage for intermediate stages" do
      exclusion = create(:ip_domain_exclusion, warmup_stage: 2)
      expect(exclusion.warmup_progress_percentage).to eq(40)
    end
  end
end
