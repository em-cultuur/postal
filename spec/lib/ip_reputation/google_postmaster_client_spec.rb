# frozen_string_literal: true

require "rails_helper"

RSpec.describe IPReputation::GooglePostmasterClient do
  let(:domain) { "example.com" }
  let(:credentials) do
    {
      access_token: "test_access_token",
      refresh_token: "test_refresh_token",
      client_id: "test_client_id",
      client_secret: "test_client_secret"
    }
  end
  let(:client) { described_class.new(domain: domain, credentials: credentials) }

  describe "#initialize" do
    it "sets the domain" do
      expect(client.domain).to eq(domain)
    end

    it "sets the credentials" do
      expect(client.credentials).to eq(credentials)
    end

    context "when credentials are not provided" do
      let(:client) { described_class.new(domain: domain) }
      let(:default_creds) do
        {
          access_token: "config_token",
          refresh_token: "config_refresh",
          client_id: "config_id",
          client_secret: "config_secret"
        }
      end

      before do
        allow_any_instance_of(described_class).to receive(:default_credentials).and_return(default_creds)
      end

      it "uses default credentials from config" do
        expect(client.credentials[:access_token]).to eq("config_token")
      end
    end
  end

  describe "#configured?" do
    context "when credentials are present" do
      it "returns true" do
        expect(client.configured?).to be true
      end
    end

    context "when credentials are missing" do
      let(:credentials) { nil }

      it "returns false" do
        expect(client.configured?).to be false
      end
    end

    context "when access_token is missing" do
      let(:credentials) { { access_token: nil } }

      it "returns false" do
        expect(client.configured?).to be false
      end
    end
  end

  describe "#fetch_reputation_data" do
    let(:date) { Date.new(2024, 1, 15) }
    let(:api_response_body) do
      {
        "name" => "domains/example.com/trafficStats/20240115",
        "domainReputation" => "HIGH",
        "spamRate" => 0.02,
        "userReportedSpamRate" => 0.01,
        "dkimSuccessRate" => 0.95,
        "spfSuccessRate" => 0.98,
        "dmarcSuccessRate" => 0.92,
        "inboundEncryptionRate" => 0.99
      }.to_json
    end

    before do
      stub_request(:get, "https://gmailpostmastertools.googleapis.com/v1/domains/example.com/trafficStats/20240115")
        .with(headers: { "Authorization" => "Bearer test_access_token" })
        .to_return(status: 200, body: api_response_body)
    end

    it "fetches reputation data successfully" do
      data = client.fetch_reputation_data(date: date)

      expect(data).to be_a(Hash)
      expect(data[:domain]).to eq(domain)
      expect(data[:domain_reputation]).to eq("HIGH")
      expect(data[:spam_rate]).to eq(0.02)
      expect(data[:user_reported_spam_rate]).to eq(0.01)
    end

    it "includes authentication rates" do
      data = client.fetch_reputation_data(date: date)

      expect(data[:dkim_success_rate]).to eq(0.95)
      expect(data[:spf_success_rate]).to eq(0.98)
      expect(data[:dmarc_success_rate]).to eq(0.92)
    end

    it "includes fetched_at timestamp" do
      data = client.fetch_reputation_data(date: date)

      expect(data[:fetched_at]).to be_within(1.second).of(Time.current)
    end

    context "when not configured" do
      let(:credentials) { nil }

      it "returns nil" do
        expect(client.fetch_reputation_data(date: date)).to be_nil
      end
    end

    context "when API returns 401 (token expired)" do
      let(:refresh_response) do
        { "access_token" => "new_access_token" }.to_json
      end

      before do
        # First request returns 401
        stub_request(:get, "https://gmailpostmastertools.googleapis.com/v1/domains/example.com/trafficStats/20240115")
          .with(headers: { "Authorization" => "Bearer test_access_token" })
          .to_return(status: 401, body: "Unauthorized")

        # Refresh token request
        stub_request(:post, "https://oauth2.googleapis.com/token")
          .with(body: hash_including(
            "refresh_token" => "test_refresh_token",
            "grant_type" => "refresh_token"
          ))
          .to_return(status: 200, body: refresh_response)

        # Retry with new token
        stub_request(:get, "https://gmailpostmastertools.googleapis.com/v1/domains/example.com/trafficStats/20240115")
          .with(headers: { "Authorization" => "Bearer new_access_token" })
          .to_return(status: 200, body: api_response_body)
      end

      it "refreshes the access token and retries" do
        data = client.fetch_reputation_data(date: date)

        expect(data).not_to be_nil
        expect(data[:domain_reputation]).to eq("HIGH")
      end

      it "updates the credentials with new access token" do
        client.fetch_reputation_data(date: date)

        expect(client.credentials[:access_token]).to eq("new_access_token")
      end
    end

    context "when API returns error" do
      before do
        stub_request(:get, "https://gmailpostmastertools.googleapis.com/v1/domains/example.com/trafficStats/20240115")
          .to_return(status: 500, body: "Internal Server Error")
      end

      it "returns nil" do
        expect(client.fetch_reputation_data(date: date)).to be_nil
      end

      it "logs the error" do
        allow(Rails.logger).to receive(:error)

        client.fetch_reputation_data(date: date)

        expect(Rails.logger).to have_received(:error).with(/Error fetching data/)
      end
    end
  end

  describe "#fetch_reputation_trend" do
    let(:start_date) { Date.new(2024, 1, 1) }
    let(:end_date) { Date.new(2024, 1, 3) }

    before do
      (start_date..end_date).each do |date|
        stub_request(:get, "https://gmailpostmastertools.googleapis.com/v1/domains/example.com/trafficStats/#{date.strftime('%Y%m%d')}")
          .to_return(status: 200, body: {
            "name" => "domains/example.com/trafficStats/#{date.strftime('%Y%m%d')}",
            "domainReputation" => "HIGH",
            "spamRate" => 0.02
          }.to_json)
      end
    end

    it "fetches data for date range" do
      trend = client.fetch_reputation_trend(start_date: start_date, end_date: end_date)

      expect(trend).to be_an(Array)
      expect(trend.size).to eq(3)
      expect(trend.all? { |d| d[:domain_reputation] == "HIGH" }).to be true
    end

    context "when not configured" do
      let(:credentials) { nil }

      it "returns empty array" do
        expect(client.fetch_reputation_trend(start_date: start_date, end_date: end_date)).to eq([])
      end
    end
  end
end
