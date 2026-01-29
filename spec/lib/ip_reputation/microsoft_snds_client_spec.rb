# frozen_string_literal: true

require "rails_helper"

RSpec.describe IPReputation::MicrosoftSndsClient do
  let(:api_key) { "test_api_key" }
  let(:client) { described_class.new(api_key: api_key) }

  describe "#initialize" do
    it "sets the api_key" do
      expect(client.api_key).to eq(api_key)
    end

    context "when api_key is not provided" do
      let(:client) { described_class.new }

      before do
        allow_any_instance_of(described_class).to receive(:default_api_key).and_return("config_api_key")
      end

      it "uses default api_key from config" do
        expect(client.api_key).to eq("config_api_key")
      end
    end
  end

  describe "#configured?" do
    context "when api_key is present" do
      it "returns true" do
        expect(client.configured?).to be true
      end
    end

    context "when api_key is missing" do
      let(:api_key) { nil }

      it "returns false" do
        expect(client.configured?).to be false
      end
    end
  end

  describe "#fetch_ip_reputation" do
    let(:ip_address) { "192.0.2.1" }
    let(:date) { Date.new(2024, 1, 15) }
    let(:csv_response) do
      <<~CSV
        IP Address,Date,Filter Result,Complaint Rate,Trap Message End Users,Trap Message Send IPs,Message Volume,Sample HELO,Sample MailFrom
        192.0.2.1,2024-01-15,green,0.001,0,0,1000,mail.example.com,sender@example.com
        192.0.2.2,2024-01-15,yellow,0.005,1,1,500,mail2.example.com,sender2@example.com
      CSV
    end

    before do
      stub_request(:get, "https://postmaster.live.com/snds/data.aspx")
        .with(headers: { "key" => "test_api_key", "date" => "2024/01/15" })
        .to_return(status: 200, body: csv_response)
    end

    it "fetches reputation data successfully" do
      data = client.fetch_ip_reputation(ip_address, date: date)

      expect(data).to be_a(Hash)
      expect(data[:ip_address]).to eq("192.0.2.1")
      expect(data[:filter_result]).to eq("green")
      expect(data[:complaint_rate]).to eq(0.001)
    end

    it "includes all SNDS fields" do
      data = client.fetch_ip_reputation(ip_address, date: date)

      expect(data[:trap_message_end_users]).to eq(0)
      expect(data[:trap_message_send_ips]).to eq(0)
      expect(data[:message_volume]).to eq(1000)
      expect(data[:sample_helo]).to eq("mail.example.com")
      expect(data[:sample_mailfrom]).to eq("sender@example.com")
    end

    it "includes severity based on filter result" do
      data = client.fetch_ip_reputation(ip_address, date: date)

      expect(data[:severity]).to eq(0) # green = 0
    end

    it "includes fetched_at timestamp" do
      data = client.fetch_ip_reputation(ip_address, date: date)

      expect(data[:fetched_at]).to be_within(1.second).of(Time.current)
    end

    context "when IP is not found in response" do
      it "returns nil" do
        data = client.fetch_ip_reputation("192.0.2.99", date: date)

        expect(data).to be_nil
      end
    end

    context "when not configured" do
      let(:api_key) { nil }

      it "returns nil" do
        expect(client.fetch_ip_reputation(ip_address, date: date)).to be_nil
      end
    end

    context "when API returns error" do
      before do
        stub_request(:get, "https://postmaster.live.com/snds/data.aspx")
          .to_return(status: 401, body: "Unauthorized")
      end

      it "returns nil" do
        expect(client.fetch_ip_reputation(ip_address, date: date)).to be_nil
      end

      it "logs the error" do
        allow(Rails.logger).to receive(:error)

        client.fetch_ip_reputation(ip_address, date: date)

        expect(Rails.logger).to have_received(:error).with(/Error fetching data/)
      end
    end
  end

  describe "#fetch_all_ips_reputation" do
    let(:date) { Date.new(2024, 1, 15) }
    let(:csv_response) do
      <<~CSV
        IP Address,Date,Filter Result,Complaint Rate,Trap Message End Users,Trap Message Send IPs,Message Volume,Sample HELO,Sample MailFrom
        192.0.2.1,2024-01-15,green,0.001,0,0,1000,mail.example.com,sender@example.com
        192.0.2.2,2024-01-15,yellow,0.005,1,1,500,mail2.example.com,sender2@example.com
        192.0.2.3,2024-01-15,red,0.015,5,3,200,mail3.example.com,sender3@example.com
      CSV
    end

    before do
      stub_request(:get, "https://postmaster.live.com/snds/data.aspx")
        .with(headers: { "key" => "test_api_key", "date" => "2024/01/15" })
        .to_return(status: 200, body: csv_response)
    end

    it "returns array of all IPs" do
      data = client.fetch_all_ips_reputation(date: date)

      expect(data).to be_an(Array)
      expect(data.size).to eq(3)
    end

    it "parses all IPs correctly" do
      data = client.fetch_all_ips_reputation(date: date)

      expect(data[0][:ip_address]).to eq("192.0.2.1")
      expect(data[1][:ip_address]).to eq("192.0.2.2")
      expect(data[2][:ip_address]).to eq("192.0.2.3")
    end

    it "includes filter results for all IPs" do
      data = client.fetch_all_ips_reputation(date: date)

      expect(data[0][:filter_result]).to eq("green")
      expect(data[1][:filter_result]).to eq("yellow")
      expect(data[2][:filter_result]).to eq("red")
    end

    context "when not configured" do
      let(:api_key) { nil }

      it "returns empty array" do
        expect(client.fetch_all_ips_reputation(date: date)).to eq([])
      end
    end
  end

  describe "#severity_for_color" do
    it "returns 0 for green" do
      expect(client.severity_for_color("green")).to eq(0)
      expect(client.severity_for_color("GREEN")).to eq(0)
    end

    it "returns 1 for yellow" do
      expect(client.severity_for_color("yellow")).to eq(1)
      expect(client.severity_for_color("YELLOW")).to eq(1)
    end

    it "returns 2 for red" do
      expect(client.severity_for_color("red")).to eq(2)
      expect(client.severity_for_color("RED")).to eq(2)
    end

    it "returns 3 for trap" do
      expect(client.severity_for_color("trap")).to eq(3)
      expect(client.severity_for_color("TRAP")).to eq(3)
    end

    it "returns nil for unknown color" do
      expect(client.severity_for_color("unknown")).to be_nil
    end

    it "handles nil input" do
      expect(client.severity_for_color(nil)).to be_nil
    end
  end
end
