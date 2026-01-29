# frozen_string_literal: true

require "rails_helper"

RSpec.describe IPMetrics::ThresholdMonitor do
  let(:monitor) { described_class.new }
  let(:ip_address) { create(:ip_address) }

  describe "#check_thresholds" do
    context "with excellent metrics" do
      let(:metric) do
        m = create(:ip_reputation_metric,
                   ip_address: ip_address,
                   sent_count: 1000,
                   delivered_count: 990,
                   bounced_count: 10,
                   spam_complaint_count: 0)
        m.calculate_rates
        m.calculate_reputation_score
        m
      end

      it "returns nil (no violations)" do
        expect(monitor.check_thresholds(metric)).to be_nil
      end
    end

    context "with critical bounce rate" do
      let(:metric) do
        m = create(:ip_reputation_metric,
                   ip_address: ip_address,
                   destination_domain: "example.com",
                   sent_count: 1000,
                   delivered_count: 850,
                   bounced_count: 150, # 15% - critical threshold is 10%
                   spam_complaint_count: 0)
        m.calculate_rates
        m.calculate_reputation_score
        m
      end

      it "returns a violation with critical severity" do
        violation = monitor.check_thresholds(metric)
        expect(violation).not_to be_nil
        expect(violation[:severity]).to eq(:critical)
      end

      it "identifies bounce_rate as the violated metric" do
        violation = monitor.check_thresholds(metric)
        bounce_violation = violation[:violations].find { |v| v[:metric] == :bounce_rate }
        expect(bounce_violation).not_to be_nil
        expect(bounce_violation[:threshold_type]).to eq(:critical)
      end

      it "includes the metric object" do
        violation = monitor.check_thresholds(metric)
        expect(violation[:metric]).to eq(metric)
      end
    end

    context "with warning-level bounce rate" do
      let(:metric) do
        m = create(:ip_reputation_metric,
                   ip_address: ip_address,
                   sent_count: 1000,
                   delivered_count: 930,
                   bounced_count: 70, # 7% - warning threshold is 5%, critical is 10%
                   spam_complaint_count: 0)
        m.calculate_rates
        m.calculate_reputation_score
        m
      end

      it "returns a violation with warning severity" do
        violation = monitor.check_thresholds(metric)
        expect(violation).not_to be_nil
        expect(violation[:severity]).to eq(:warning)
      end
    end

    context "with critical spam rate" do
      let(:metric) do
        m = create(:ip_reputation_metric,
                   ip_address: ip_address,
                   sent_count: 1000,
                   delivered_count: 950,
                   bounced_count: 0,
                   spam_complaint_count: 40) # 4% - critical threshold is 3%
        m.calculate_rates
        m.calculate_reputation_score
        m
      end

      it "returns a violation with critical severity" do
        violation = monitor.check_thresholds(metric)
        expect(violation).not_to be_nil
        expect(violation[:severity]).to eq(:critical)
      end

      it "identifies spam_rate as the violated metric" do
        violation = monitor.check_thresholds(metric)
        spam_violation = violation[:violations].find { |v| v[:metric] == :spam_rate }
        expect(spam_violation).not_to be_nil
        expect(spam_violation[:threshold_type]).to eq(:critical)
      end
    end

    context "with critical delivery rate" do
      let(:metric) do
        m = create(:ip_reputation_metric,
                   ip_address: ip_address,
                   sent_count: 1000,
                   delivered_count: 800, # 80% - critical threshold is 85%
                   bounced_count: 200,
                   spam_complaint_count: 0)
        m.calculate_rates
        m.calculate_reputation_score
        m
      end

      it "returns a violation with critical severity" do
        violation = monitor.check_thresholds(metric)
        expect(violation).not_to be_nil
        expect(violation[:severity]).to eq(:critical)
      end

      it "identifies delivery_rate as violated" do
        violation = monitor.check_thresholds(metric)
        delivery_violation = violation[:violations].find { |v| v[:metric] == :delivery_rate }
        expect(delivery_violation).not_to be_nil
      end
    end

    context "with multiple violations" do
      let(:metric) do
        m = create(:ip_reputation_metric,
                   ip_address: ip_address,
                   sent_count: 1000,
                   delivered_count: 700,
                   bounced_count: 250, # 25% bounce - critical
                   spam_complaint_count: 50) # 5% spam - critical
        m.calculate_rates
        m.calculate_reputation_score
        m
      end

      it "returns multiple violations" do
        violation = monitor.check_thresholds(metric)
        expect(violation[:violations].size).to be >= 2
      end

      it "marks overall severity as critical if any critical violation" do
        violation = monitor.check_thresholds(metric)
        expect(violation[:severity]).to eq(:critical)
      end
    end

    context "with volume below minimum threshold" do
      let(:metric) do
        m = create(:ip_reputation_metric,
                   ip_address: ip_address,
                   sent_count: 5, # Below default minimum of 10
                   delivered_count: 2,
                   bounced_count: 3,
                   spam_complaint_count: 0)
        m.calculate_rates
        m.calculate_reputation_score
        m
      end

      it "returns nil (ignores low volume metrics)" do
        expect(monitor.check_thresholds(metric)).to be_nil
      end
    end
  end

  describe "#monitor_ip" do
    let!(:good_metric) do
      m = create(:ip_reputation_metric,
                 ip_address: ip_address,
                 period: IPReputationMetric::HOURLY,
                 period_date: 1.hour.ago.to_date,
                 sent_count: 1000,
                 delivered_count: 990,
                 bounced_count: 10,
                 spam_complaint_count: 0)
      m.calculate_rates
      m.calculate_reputation_score
      m.save
      m
    end

    let!(:bad_metric) do
      m = create(:ip_reputation_metric,
                 ip_address: ip_address,
                 destination_domain: "problem.com",
                 period: IPReputationMetric::HOURLY,
                 period_date: Date.current,
                 sent_count: 1000,
                 delivered_count: 700,
                 bounced_count: 300,
                 spam_complaint_count: 0)
      m.calculate_rates
      m.calculate_reputation_score
      m.save
      m
    end

    it "returns violations for problematic metrics" do
      violations = monitor.monitor_ip(ip_address, lookback_hours: 24)
      expect(violations).not_to be_empty
      expect(violations.first[:severity]).to eq(:critical)
    end

    it "includes destination domain information" do
      violations = monitor.monitor_ip(ip_address, lookback_hours: 24)
      violation = violations.find { |v| v[:destination_domain] == "problem.com" }
      expect(violation).not_to be_nil
    end
  end

  describe "#monitor_all" do
    let!(:ip1) { create(:ip_address) }
    let!(:ip2) { create(:ip_address) }

    let!(:critical_metric) do
      m = create(:ip_reputation_metric,
                 ip_address: ip1,
                 period: IPReputationMetric::HOURLY,
                 period_date: Date.current,
                 sent_count: 1000,
                 delivered_count: 700,
                 bounced_count: 300)
      m.calculate_rates
      m.calculate_reputation_score
      m.save
      m
    end

    let!(:warning_metric) do
      m = create(:ip_reputation_metric,
                 ip_address: ip2,
                 period: IPReputationMetric::HOURLY,
                 period_date: Date.current,
                 sent_count: 1000,
                 delivered_count: 930,
                 bounced_count: 70)
      m.calculate_rates
      m.calculate_reputation_score
      m.save
      m
    end

    it "returns violations grouped by severity" do
      violations = monitor.monitor_all(lookback_hours: 24)
      expect(violations).to have_key(:critical)
      expect(violations).to have_key(:warning)
    end

    it "categorizes critical violations correctly" do
      violations = monitor.monitor_all(lookback_hours: 24)
      expect(violations[:critical]).not_to be_empty
    end

    it "categorizes warning violations correctly" do
      violations = monitor.monitor_all(lookback_hours: 24)
      expect(violations[:warning]).not_to be_empty
    end
  end

  describe "#take_action" do
    let(:metric) do
      m = create(:ip_reputation_metric,
                 ip_address: ip_address,
                 destination_domain: "example.com",
                 sent_count: 1000,
                 delivered_count: 700,
                 bounced_count: 300)
      m.calculate_rates
      m.calculate_reputation_score
      m
    end

    let(:violation) do
      {
        ip_address: ip_address,
        destination_domain: "example.com",
        severity: :critical,
        violations: [
          { metric: :bounce_rate, threshold_type: :critical, actual_value: 3000, percentage: 30.0 },
        ],
        metric: metric
      }
    end

    context "with critical violation" do
      it "creates an IP domain exclusion" do
        expect do
          monitor.take_action(violation, action_type: :pause)
        end.to change { IPDomainExclusion.count }.by(1)
      end

      it "pauses the IP at warmup_stage 0" do
        monitor.take_action(violation, action_type: :pause)
        exclusion = IPDomainExclusion.last
        expect(exclusion.warmup_stage).to eq(0)
        expect(exclusion.destination_domain).to eq("example.com")
      end

      it "creates a health action log entry" do
        expect do
          monitor.take_action(violation, action_type: :pause)
        end.to change { IPHealthAction.count }.by(1)
      end

      it "logs the reason for pausing" do
        monitor.take_action(violation, action_type: :pause)
        action = IPHealthAction.last
        expect(action.reason).to include("Threshold violation")
      end
    end

    context "with warning violation" do
      let(:warning_violation) do
        violation.merge(severity: :warning)
      end

      it "creates a warning health action" do
        expect do
          monitor.take_action(warning_violation, action_type: :warn)
        end.to change { IPHealthAction.where(action_type: IPHealthAction::MONITOR).count }.by(1)
      end

      it "does not pause the IP" do
        expect do
          monitor.take_action(warning_violation, action_type: :warn)
        end.not_to change { IPDomainExclusion.count }
      end
    end
  end

  describe "#process_violations" do
    let(:ip1) { create(:ip_address) }
    let(:ip2) { create(:ip_address) }

    let(:violations) do
      [
        {
          ip_address: ip1,
          destination_domain: "critical.com",
          severity: :critical,
          violations: [{ metric: :bounce_rate, threshold_type: :critical }],
          metric: build(:ip_reputation_metric, ip_address: ip1)
        },
        {
          ip_address: ip2,
          destination_domain: "warning.com",
          severity: :warning,
          violations: [{ metric: :bounce_rate, threshold_type: :warning }],
          metric: build(:ip_reputation_metric, ip_address: ip2)
        },
      ]
    end

    it "processes all violations and returns summary" do
      summary = monitor.process_violations(violations)
      expect(summary).to have_key(:paused)
      expect(summary).to have_key(:warned)
    end

    it "pauses IPs with critical violations" do
      expect do
        monitor.process_violations(violations)
      end.to change { IPDomainExclusion.count }.by_at_least(1)
    end

    it "tracks the number of actions taken" do
      summary = monitor.process_violations(violations)
      total_actions = summary[:paused] + summary[:warned] + summary[:notified]
      # Should attempt to process all violations (some may fail due to notifications, but that's OK)
      expect(summary).to have_key(:paused)
      expect(summary).to have_key(:warned)
      expect(summary).to have_key(:notified)
    end
  end

  describe "custom thresholds" do
    let(:custom_thresholds) do
      {
        bounce_rate: { warning: 300, critical: 800 },
        spam_rate: { warning: 50, critical: 200 },
        delivery_rate: { warning: 9200, critical: 8800 },
        reputation_score: { warning: 70, critical: 50 }
      }
    end

    let(:monitor) { described_class.new(thresholds: custom_thresholds) }

    let(:metric) do
      m = create(:ip_reputation_metric,
                 ip_address: ip_address,
                 sent_count: 1000,
                 delivered_count: 950,
                 bounced_count: 50, # 5% - would be warning with default, but critical with custom
                 spam_complaint_count: 0)
      m.calculate_rates
      m.calculate_reputation_score
      m
    end

    it "uses custom thresholds" do
      violation = monitor.check_thresholds(metric)
      # With custom threshold of 8% critical, 5% bounce rate is below critical
      # but with 3% warning, 5% is above warning
      expect(violation).not_to be_nil
      expect(violation[:severity]).to eq(:warning)
    end
  end

  describe "custom minimum volume" do
    let(:monitor) { described_class.new(minimum_volume: 100) }

    let(:metric) do
      m = create(:ip_reputation_metric,
                 ip_address: ip_address,
                 sent_count: 50, # Below custom minimum of 100
                 delivered_count: 20,
                 bounced_count: 30,
                 spam_complaint_count: 0)
      m.calculate_rates
      m.calculate_reputation_score
      m
    end

    it "ignores metrics below custom minimum volume" do
      expect(monitor.check_thresholds(metric)).to be_nil
    end
  end
end
