# frozen_string_literal: true

# == Schema Information
#
# Table name: mx_rate_limit_patterns
#
#  id              :integer          not null, primary key
#  action          :string(255)
#  enabled         :boolean          default(TRUE)
#  name            :string(255)      not null
#  pattern         :text(65535)      not null
#  priority        :integer          default(0)
#  suggested_delay :integer
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
# Indexes
#
#  index_mx_rate_limit_patterns_on_enabled   (enabled)
#  index_mx_rate_limit_patterns_on_priority  (priority)
#
require "rails_helper"

RSpec.describe MXRateLimitPattern do
  # Clear default patterns that are created by migrations
  before(:all) { MXRateLimitPattern.delete_all }

  describe "validations" do
    it "requires a name" do
      pattern = MXRateLimitPattern.new(pattern: '\b421\b', action: "rate_limit")
      expect(pattern).not_to be_valid
      expect(pattern.errors[:name]).to include("can't be blank")
    end

    it "requires a pattern" do
      pattern = MXRateLimitPattern.new(name: "Test", action: "rate_limit")
      expect(pattern).not_to be_valid
      expect(pattern.errors[:pattern]).to include("can't be blank")
    end

    it "validates action is one of VALID_ACTIONS" do
      pattern = MXRateLimitPattern.new(name: "Test", pattern: '\b421\b', action: "invalid_action")
      expect(pattern).not_to be_valid
      expect(pattern.errors[:action]).to be_present
    end

    it "allows valid actions" do
      MXRateLimitPattern::VALID_ACTIONS.each do |action|
        pattern = MXRateLimitPattern.new(name: "Test", pattern: '\b421\b', action: action)
        expect(pattern).to be_valid
      end
    end
  end

  describe ".match_message" do
    let!(:pattern1) { create(:mx_rate_limit_pattern, pattern: '\b421\b.*\btoo many\b', priority: 100) }
    let!(:pattern2) { create(:mx_rate_limit_pattern, pattern: '\b450\b', priority: 90) }
    let!(:disabled_pattern) { create(:mx_rate_limit_pattern, :disabled, pattern: '\b500\b') }

    it "returns the first matching pattern" do
      message = "421 4.7.0 too many connections"
      expect(MXRateLimitPattern.match_message(message)).to eq(pattern1)
    end

    it "returns nil when no pattern matches" do
      message = "250 OK"
      expect(MXRateLimitPattern.match_message(message)).to be_nil
    end

    it "returns nil when message is blank" do
      expect(MXRateLimitPattern.match_message("")).to be_nil
      expect(MXRateLimitPattern.match_message(nil)).to be_nil
    end

    it "respects priority order" do
      # Create a third pattern with lower priority that matches "421"
      pattern3 = create(:mx_rate_limit_pattern, pattern: '\b421\b', priority: 50)
      message = "421 4.7.0 too many connections"
      # pattern1 has higher priority (100) and matches, pattern3 would also match but has lower priority
      result = MXRateLimitPattern.match_message(message)
      expect(result.priority).to eq(100)
    end

    it "ignores disabled patterns" do
      message = "500 Internal error"
      expect(MXRateLimitPattern.match_message(message)).to be_nil
    end
  end

  describe ".create_defaults!" do
    before { MXRateLimitPattern.delete_all }

    it "creates all default patterns" do
      expect do
        MXRateLimitPattern.create_defaults!
      end.to change(MXRateLimitPattern, :count).by(6)
    end

    it "does not duplicate existing patterns" do
      MXRateLimitPattern.create_defaults!
      expect do
        MXRateLimitPattern.create_defaults!
      end.not_to change(MXRateLimitPattern, :count)
    end

    it "creates patterns with correct priorities" do
      MXRateLimitPattern.create_defaults!
      priorities = MXRateLimitPattern.pluck(:priority)
      expect(priorities).to include(100, 90, 80, 70, 60, 50)
    end

    it "creates rate_limit and hard_fail actions" do
      MXRateLimitPattern.create_defaults!
      actions = MXRateLimitPattern.pluck(:action).uniq
      expect(actions).to contain_exactly("rate_limit", "hard_fail")
    end
  end

  describe "#match?" do
    let(:pattern) { create(:mx_rate_limit_pattern, pattern: '\b421\b.*\btoo many\b') }

    it "returns true for matching messages" do
      expect(pattern.match?("421 4.7.0 too many connections")).to be true
    end

    it "returns false for non-matching messages" do
      expect(pattern.match?("250 OK")).to be false
    end

    it "is case-insensitive" do
      expect(pattern.match?("421 TOO MANY")).to be true
      expect(pattern.match?("421 Too Many")).to be true
    end

    it "returns false when message is blank" do
      expect(pattern.match?("")).to be false
      expect(pattern.match?(nil)).to be false
    end

    it "handles invalid regex gracefully" do
      pattern.update_column(:pattern, "[invalid(regex")
      expect(pattern.match?("some message")).to be false
    end
  end

  describe "scopes" do
    let!(:enabled1) { create(:mx_rate_limit_pattern, enabled: true, priority: 100) }
    let!(:enabled2) { create(:mx_rate_limit_pattern, enabled: true, priority: 50) }
    let!(:disabled) { create(:mx_rate_limit_pattern, :disabled) }

    describe ".enabled" do
      it "returns only enabled patterns" do
        expect(MXRateLimitPattern.enabled).to contain_exactly(enabled1, enabled2)
      end
    end

    describe ".ordered" do
      it "returns patterns ordered by priority DESC" do
        expect(MXRateLimitPattern.enabled.ordered).to eq([enabled1, enabled2])
      end
    end
  end
end
