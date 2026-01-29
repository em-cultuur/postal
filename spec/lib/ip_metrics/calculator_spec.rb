# frozen_string_literal: true

require "rails_helper"

RSpec.describe IPMetrics::Calculator do
  describe ".calculate_reputation_score" do
    let(:ip_address) { create(:ip_address) }
    let(:metric) do
      create(:ip_reputation_metric,
             ip_address: ip_address,
             sent_count: 1000,
             delivered_count: delivered,
             bounced_count: bounced,
             hard_fail_count: hard_fails,
             soft_fail_count: soft_fails,
             spam_complaint_count: spam)
    end

    context "with excellent metrics" do
      let(:delivered) { 990 }
      let(:bounced) { 10 }
      let(:hard_fails) { 2 }
      let(:soft_fails) { 8 }
      let(:spam) { 0 }

      it "returns a high score" do
        metric.calculate_rates
        score = described_class.calculate_reputation_score(metric)
        expect(score).to be >= 90
      end

      it "sets the reputation_score on the metric" do
        metric.calculate_rates
        described_class.calculate_reputation_score(metric)
        expect(metric.reputation_score).to be >= 90
      end
    end

    context "with high bounce rate" do
      let(:delivered) { 850 }
      let(:bounced) { 150 } # 15% bounce rate
      let(:hard_fails) { 100 }
      let(:soft_fails) { 50 }
      let(:spam) { 0 }

      it "returns a low score" do
        metric.calculate_rates
        score = described_class.calculate_reputation_score(metric)
        expect(score).to be < 70 # Penalized but not critical
      end
    end

    context "with high spam rate" do
      let(:delivered) { 950 }
      let(:bounced) { 0 }
      let(:hard_fails) { 0 }
      let(:soft_fails) { 0 }
      let(:spam) { 50 } # 5% spam rate

      it "returns a penalized score" do
        metric.calculate_rates
        score = described_class.calculate_reputation_score(metric)
        expect(score).to be < 80 # Spam heavily penalized but good delivery helps
      end
    end

    context "with no data" do
      let(:delivered) { 0 }
      let(:bounced) { 0 }
      let(:hard_fails) { 0 }
      let(:soft_fails) { 0 }
      let(:spam) { 0 }

      before do
        metric.sent_count = 0
      end

      it "returns 100 (innocent until proven guilty)" do
        score = described_class.calculate_reputation_score(metric)
        expect(score).to eq(100)
      end
    end

    context "with mostly hard failures" do
      let(:delivered) { 900 }
      let(:bounced) { 100 }
      let(:hard_fails) { 95 } # 95% of failures are hard
      let(:soft_fails) { 5 }
      let(:spam) { 0 }

      it "penalizes inconsistent delivery (list quality issues)" do
        metric.calculate_rates
        score = described_class.calculate_reputation_score(metric)
        expect(score).to be < 80
      end
    end
  end

  describe ".calculate_rates" do
    let(:ip_address) { create(:ip_address) }
    let(:metric) do
      create(:ip_reputation_metric,
             ip_address: ip_address,
             sent_count: 1000,
             delivered_count: 950,
             bounced_count: 50,
             spam_complaint_count: 5)
    end

    it "calculates bounce rate as integer * 10000" do
      described_class.calculate_rates(metric)
      expect(metric.bounce_rate).to eq(500) # 5% = 500 (stored as 5 * 100)
    end

    it "calculates delivery rate as integer * 10000" do
      described_class.calculate_rates(metric)
      expect(metric.delivery_rate).to eq(9500) # 95% = 9500
    end

    it "calculates spam rate as integer * 10000" do
      described_class.calculate_rates(metric)
      expect(metric.spam_rate).to eq(50) # 0.5% = 50
    end

    it "does nothing if sent_count is zero" do
      metric.sent_count = 0
      described_class.calculate_rates(metric)
      expect(metric.bounce_rate).to eq(0)
    end
  end

  describe ".reputation_status" do
    it "returns :excellent for scores 90-100" do
      expect(described_class.reputation_status(95)).to eq(:excellent)
      expect(described_class.reputation_status(100)).to eq(:excellent)
    end

    it "returns :good for scores 75-89" do
      expect(described_class.reputation_status(80)).to eq(:good)
      expect(described_class.reputation_status(75)).to eq(:good)
    end

    it "returns :fair for scores 60-74" do
      expect(described_class.reputation_status(65)).to eq(:fair)
      expect(described_class.reputation_status(60)).to eq(:fair)
    end

    it "returns :poor for scores 40-59" do
      expect(described_class.reputation_status(50)).to eq(:poor)
      expect(described_class.reputation_status(40)).to eq(:poor)
    end

    it "returns :critical for scores 0-39" do
      expect(described_class.reputation_status(20)).to eq(:critical)
      expect(described_class.reputation_status(0)).to eq(:critical)
    end
  end

  describe ".bounce_rate_status" do
    it "returns :excellent for very low bounce rates" do
      expect(described_class.bounce_rate_status(100)).to eq(:excellent) # 1%
    end

    it "returns :acceptable for moderate bounce rates" do
      expect(described_class.bounce_rate_status(300)).to eq(:acceptable) # 3%
    end

    it "returns :warning for elevated bounce rates" do
      expect(described_class.bounce_rate_status(700)).to eq(:warning) # 7%
    end

    it "returns :critical for very high bounce rates" do
      expect(described_class.bounce_rate_status(2500)).to eq(:critical) # 25%
    end
  end

  describe ".spam_rate_status" do
    it "returns :excellent for very low spam rates" do
      expect(described_class.spam_rate_status(5)).to eq(:excellent) # 0.05%
    end

    it "returns :acceptable for moderate spam rates" do
      expect(described_class.spam_rate_status(50)).to eq(:acceptable) # 0.5%
    end

    it "returns :warning for elevated spam rates" do
      expect(described_class.spam_rate_status(200)).to eq(:warning) # 2%
    end

    it "returns :critical for high spam rates" do
      expect(described_class.spam_rate_status(500)).to eq(:critical) # 5%
    end
  end

  describe ".delivery_rate_status" do
    it "returns :excellent for very high delivery rates" do
      expect(described_class.delivery_rate_status(9900)).to eq(:excellent) # 99%
    end

    it "returns :acceptable for good delivery rates" do
      expect(described_class.delivery_rate_status(9600)).to eq(:acceptable) # 96%
    end

    it "returns :warning for low delivery rates" do
      expect(described_class.delivery_rate_status(9200)).to eq(:warning) # 92%
    end

    it "returns :critical for very low delivery rates" do
      expect(described_class.delivery_rate_status(8000)).to eq(:critical) # 80%
    end
  end

  describe ".analyze_metric" do
    let(:ip_address) { create(:ip_address) }
    let(:metric) do
      m = create(:ip_reputation_metric,
                 ip_address: ip_address,
                 sent_count: 1000,
                 delivered_count: delivered,
                 bounced_count: bounced,
                 hard_fail_count: hard_fails,
                 soft_fail_count: soft_fails,
                 spam_complaint_count: spam)
      m.calculate_rates
      m.calculate_reputation_score
      m
    end

    context "with critical metrics" do
      let(:delivered) { 600 }
      let(:bounced) { 400 } # 40% bounce rate - extremely critical
      let(:hard_fails) { 350 }
      let(:soft_fails) { 50 }
      let(:spam) { 50 } # 5% spam rate - also critical

      it "returns critical status" do
        analysis = described_class.analyze_metric(metric)
        expect(analysis[:status]).to eq(:critical)
      end

      it "identifies issues" do
        analysis = described_class.analyze_metric(metric)
        expect(analysis[:issues]).not_to be_empty
        expect(analysis[:issues].join(" ")).to include("bounce rate")
      end

      it "provides recommendations" do
        analysis = described_class.analyze_metric(metric)
        expect(analysis[:recommendations]).not_to be_empty
        expect(analysis[:recommendations].first).to include("pause")
      end
    end

    context "with excellent metrics" do
      let(:delivered) { 990 }
      let(:bounced) { 10 }
      let(:hard_fails) { 2 }
      let(:soft_fails) { 8 }
      let(:spam) { 0 }

      it "returns excellent status" do
        analysis = described_class.analyze_metric(metric)
        expect(analysis[:status]).to eq(:excellent)
      end

      it "has no issues" do
        analysis = described_class.analyze_metric(metric)
        expect(analysis[:issues]).to be_empty
      end
    end

    context "with no data" do
      let(:delivered) { 0 }
      let(:bounced) { 0 }
      let(:hard_fails) { 0 }
      let(:soft_fails) { 0 }
      let(:spam) { 0 }

      before do
        metric.sent_count = 0
      end

      it "returns no_data status" do
        analysis = described_class.analyze_metric(metric)
        expect(analysis[:status]).to eq(:no_data)
      end
    end
  end

  describe ".calculate_trend" do
    let(:ip_address) { create(:ip_address) }
    let(:latest_metric) do
      m = create(:ip_reputation_metric,
                 ip_address: ip_address,
                 period_date: Date.current,
                 sent_count: 1000,
                 delivered_count: 950,
                 bounced_count: 50)
      m.calculate_rates
      m.calculate_reputation_score
      m.save
      m
    end
    let(:previous_metric) do
      m = create(:ip_reputation_metric,
                 ip_address: ip_address,
                 period_date: Date.yesterday,
                 sent_count: 1000,
                 delivered_count: 900,
                 bounced_count: 100)
      m.calculate_rates
      m.calculate_reputation_score
      m.save
      m
    end

    it "detects improving trend" do
      trend = described_class.calculate_trend([latest_metric, previous_metric])
      expect(trend[:trend]).to eq(:improving)
      expect(trend[:score_change]).to be > 0
    end

    it "detects degrading trend" do
      # Swap order to make latest worse than previous
      trend = described_class.calculate_trend([previous_metric, latest_metric])
      expect(trend[:trend]).to eq(:degrading)
      expect(trend[:score_change]).to be < 0
    end

    it "detects stable trend" do
      # Make both metrics identical
      previous_metric.update!(
        delivered_count: latest_metric.delivered_count,
        bounced_count: latest_metric.bounced_count
      )
      previous_metric.calculate_rates
      previous_metric.calculate_reputation_score
      previous_metric.save

      trend = described_class.calculate_trend([latest_metric, previous_metric])
      expect(trend[:trend]).to eq(:stable)
    end

    it "returns insufficient_data with less than 2 metrics" do
      trend = described_class.calculate_trend([latest_metric])
      expect(trend[:trend]).to eq(:insufficient_data)
    end
  end
end
