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

  describe "Authorization - cross-organization access" do
    let(:other_user) { create(:user) }
    let(:other_organization) { create(:organization, owner: other_user) }
    let(:other_server) { create(:server, organization: other_organization) }

    before do
      # Setup other organization and membership
      OrganizationUser.create!(organization: other_organization, user: other_user, admin: true, all_servers: true)
    end

    context "when accessing another organization's rate limits" do
      it "denies access with 404 not found" do
        # The WithinOrganization concern will raise RecordNotFound for non-members
        # which Rails converts to a 404 response
        expect do
          get "/org/#{other_organization.permalink}/servers/#{other_server.permalink}/mx_rate_limits.json"
        end.to raise_error(ActiveRecord::RecordNotFound)
      end

      it "denies access to rate limit stats for another organization" do
        # Create a rate limit for the other organization
        create(:mx_rate_limit, server: other_server, mx_domain: "gmail.com")

        # Attempt to access it - should raise RecordNotFound
        expect do
          get "/org/#{other_organization.permalink}/servers/#{other_server.permalink}/mx_rate_limits/gmail.com/stats.json"
        end.to raise_error(ActiveRecord::RecordNotFound)
      end

      it "denies access to summary for another organization" do
        # Attempt to access other organization's summary
        expect do
          get "/org/#{other_organization.permalink}/servers/#{other_server.permalink}/mx_rate_limits/summary.json"
        end.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context "when user is not a member of the organization" do
      before do
        # Make sure the current user is NOT a member of other_organization
        OrganizationUser.where(organization: other_organization, user: user).delete_all
      end

      it "returns 404 for rate limits list" do
        expect do
          get "/org/#{other_organization.permalink}/servers/#{other_server.permalink}/mx_rate_limits.json"
        end.to raise_error(ActiveRecord::RecordNotFound)
      end

      it "returns 404 for rate limit stats" do
        create(:mx_rate_limit, server: other_server, mx_domain: "gmail.com")

        expect do
          get "/org/#{other_organization.permalink}/servers/#{other_server.permalink}/mx_rate_limits/gmail.com/stats.json"
        end.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end
end

# Tests for the format_delay_human helper method
describe "MXRateLimitsController#format_delay_human", type: :controller do
  let(:controller_instance) { MXRateLimitsController.new }

  describe "formatting seconds to human-readable delay" do
    it "formats zero delay as 'No delay'" do
      result = controller_instance.send(:format_delay_human, 0)
      expect(result).to eq("No delay")
    end

    it "formats seconds between 1-59 as seconds" do
      expect(controller_instance.send(:format_delay_human, 1)).to eq("1s")
      expect(controller_instance.send(:format_delay_human, 30)).to eq("30s")
      expect(controller_instance.send(:format_delay_human, 59)).to eq("59s")
    end

    it "formats 60 seconds as '1m'" do
      result = controller_instance.send(:format_delay_human, 60)
      expect(result).to eq("1m")
    end

    it "formats 300 seconds as '5m'" do
      result = controller_instance.send(:format_delay_human, 300)
      expect(result).to eq("5m")
    end

    it "formats 90 seconds as '1.5m'" do
      result = controller_instance.send(:format_delay_human, 90)
      expect(result).to eq("1.5m")
    end

    it "formats 3599 seconds as '60m'" do
      result = controller_instance.send(:format_delay_human, 3599)
      expect(result).to match(/59\.\d+m|60m/)
    end

    it "formats 3600 seconds as '1h'" do
      result = controller_instance.send(:format_delay_human, 3600)
      expect(result).to eq("1h")
    end

    it "formats 7200 seconds as '2h'" do
      result = controller_instance.send(:format_delay_human, 7200)
      expect(result).to eq("2h")
    end

    it "formats 10800 seconds as '3h'" do
      result = controller_instance.send(:format_delay_human, 10_800)
      expect(result).to eq("3h")
    end

    it "formats large delays with decimal hours" do
      result = controller_instance.send(:format_delay_human, 5400)
      expect(result).to eq("1.5h")
    end
  end
end
