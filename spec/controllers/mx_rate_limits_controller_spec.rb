# frozen_string_literal: true

require "rails_helper"

RSpec.describe "MxRateLimits API", type: :request do
  let(:user) { create(:user) }
  let(:organization) { create(:organization, owner: user) }
  let(:server) { create(:server, organization: organization) }

  before do
    # Create organization membership for the user
    OrganizationUser.create!(organization: organization, user: user, admin: true, all_servers: true)

    # Skip authentication for these tests
    allow_any_instance_of(ApplicationController).to receive(:login_required).and_return(true)
    allow_any_instance_of(ApplicationController).to receive(:logged_in?).and_return(true)
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(user)
  end

  describe "GET /org/:org_permalink/servers/:server_id/mx_rate_limits" do
    context "when there are active rate limits" do
      let!(:rate_limit1) do
        create(:mx_rate_limit,
               server: server,
               mx_domain: "gmail.com",
               error_count: 3,
               current_delay: 900)
      end

      let!(:rate_limit2) do
        create(:mx_rate_limit,
               server: server,
               mx_domain: "yahoo.com",
               error_count: 2,
               current_delay: 600)
      end

      let!(:inactive_rate_limit) do
        create(:mx_rate_limit,
               server: server,
               mx_domain: "hotmail.com",
               error_count: 0,
               current_delay: 0)
      end

      it "returns active rate limits as JSON" do
        get "/org/#{organization.permalink}/servers/#{server.permalink}/mx_rate_limits.json"

        expect(response).to have_http_status(:ok)
        parsed_body = JSON.parse(response.body)

        expect(parsed_body["rate_limits"]).to be_an(Array)
        expect(parsed_body["rate_limits"].length).to eq(2)

        mx_domains = parsed_body["rate_limits"].map { |rl| rl["mx_domain"] }
        expect(mx_domains).to contain_exactly("gmail.com", "yahoo.com")

        gmail_limit = parsed_body["rate_limits"].find { |rl| rl["mx_domain"] == "gmail.com" }
        expect(gmail_limit["error_count"]).to eq(3)
        expect(gmail_limit["current_delay_seconds"]).to eq(900)
      end
    end

    context "when there are no active rate limits" do
      it "returns an empty array" do
        get "/org/#{organization.permalink}/servers/#{server.permalink}/mx_rate_limits.json"

        expect(response).to have_http_status(:ok)
        parsed_body = JSON.parse(response.body)

        expect(parsed_body["rate_limits"]).to eq([])
      end
    end
  end

  describe "GET /org/:org_permalink/servers/:server_id/mx_rate_limits/summary" do
    let!(:active_rate_limit) do
      create(:mx_rate_limit,
             server: server,
             mx_domain: "gmail.com",
             error_count: 3,
             current_delay: 900)
    end

    let!(:inactive_rate_limit) do
      create(:mx_rate_limit,
             server: server,
             mx_domain: "yahoo.com",
             error_count: 0,
             current_delay: 0)
    end

    let!(:event1) { create(:mx_rate_limit_event, server: server, mx_domain: "gmail.com", event_type: "error", created_at: 1.hour.ago) }
    let!(:event2) { create(:mx_rate_limit_event, server: server, mx_domain: "gmail.com", event_type: "success", created_at: 30.minutes.ago) }
    let!(:old_event) { create(:mx_rate_limit_event, server: server, mx_domain: "gmail.com", event_type: "error", created_at: 2.days.ago) }

    it "returns summary statistics" do
      get "/org/#{organization.permalink}/servers/#{server.permalink}/mx_rate_limits/summary.json"

      expect(response).to have_http_status(:ok)
      parsed_body = JSON.parse(response.body)

      expect(parsed_body["summary"]["active_rate_limits"]).to eq(1)
      expect(parsed_body["summary"]["total_rate_limits"]).to eq(2)
      expect(parsed_body["summary"]["events_last_24h"]).to eq(2)
      expect(parsed_body["summary"]["errors_last_24h"]).to eq(1)
      expect(parsed_body["summary"]["successes_last_24h"]).to eq(1)
    end
  end

  describe "GET /org/:org_permalink/servers/:server_id/mx_rate_limits (HTML dashboard)" do
    context "when MX rate limiting is enabled" do
      before do
        allow(Postal::Config.postal).to receive(:mx_rate_limiting_enabled).and_return(true)
      end

      let!(:rate_limit) do
        create(:mx_rate_limit,
               server: server,
               mx_domain: "gmail.com",
               error_count: 3,
               success_count: 5,
               current_delay: 900)
      end

      let!(:event) { create(:mx_rate_limit_event, server: server, event_type: "error", created_at: 1.hour.ago) }

      it "assigns rate limits to the view" do
        get "/org/#{organization.permalink}/servers/#{server.permalink}/mx_rate_limits", params: { format: :json }

        expect(response).to have_http_status(:ok)
        parsed_body = JSON.parse(response.body)
        expect(parsed_body["rate_limits"]).to include(hash_including("mx_domain" => "gmail.com"))
      end

      it "returns JSON for API consumption" do
        get "/org/#{organization.permalink}/servers/#{server.permalink}/mx_rate_limits", params: { format: :json }

        expect(response).to have_http_status(:ok)
        expect(response.content_type).to include("application/json")
        parsed_body = JSON.parse(response.body)
        expect(parsed_body.key?("rate_limits")).to be true
      end
    end

    context "when MX rate limiting is disabled" do
      before do
        allow(Postal::Config.postal).to receive(:mx_rate_limiting_enabled).and_return(false)
      end

      it "still returns JSON data" do
        get "/org/#{organization.permalink}/servers/#{server.permalink}/mx_rate_limits", params: { format: :json }

        expect(response).to have_http_status(:ok)
        parsed_body = JSON.parse(response.body)
        expect(parsed_body.key?("rate_limits")).to be true
      end
    end
  end

  describe "GET /org/:org_permalink/servers/:server_id/mx_rate_limits/:id/stats" do
    let!(:rate_limit) do
      create(:mx_rate_limit,
             server: server,
             mx_domain: "gmail.com",
             error_count: 3,
             success_count: 0,
             current_delay: 900,
             last_error_message: "421 4.7.0 Try again later")
    end

    let!(:event1) { create(:mx_rate_limit_event, server: server, mx_domain: "gmail.com", event_type: "error", smtp_response: "421 Try later", created_at: 1.hour.ago) }
    let!(:event2) { create(:mx_rate_limit_event, server: server, mx_domain: "gmail.com", event_type: "success", created_at: 30.minutes.ago) }
    let!(:old_event) { create(:mx_rate_limit_event, server: server, mx_domain: "gmail.com", event_type: "error", created_at: 2.days.ago) }

    context "when rate limit exists" do
      it "returns detailed statistics for the MX domain" do
        get "/org/#{organization.permalink}/servers/#{server.permalink}/mx_rate_limits/gmail.com/stats", params: { format: :json }

        expect(response).to have_http_status(:ok)
        parsed_body = JSON.parse(response.body)

        expect(parsed_body["rate_limit"]["mx_domain"]).to eq("gmail.com")
        expect(parsed_body["rate_limit"]["error_count"]).to eq(3)
        expect(parsed_body["rate_limit"]["success_count"]).to eq(0)
        expect(parsed_body["rate_limit"]["current_delay_seconds"]).to eq(900)
        expect(parsed_body["rate_limit"]["last_error_message"]).to eq("421 4.7.0 Try again later")

        expect(parsed_body["events_last_24h"]).to be_an(Array)
        expect(parsed_body["events_last_24h"].length).to eq(2)

        event_types = parsed_body["events_last_24h"].map { |e| e["event_type"] }
        expect(event_types).to contain_exactly("error", "success")
      end
    end

    context "when rate limit does not exist" do
      it "returns 404 not found" do
        get "/org/#{organization.permalink}/servers/#{server.permalink}/mx_rate_limits/nonexistent.com/stats", params: { format: :json }

        expect(response).to have_http_status(:not_found)
        parsed_body = JSON.parse(response.body)

        expect(parsed_body["error"]).to match(/Rate limit not found/)
      end
    end
  end
end
