# frozen_string_literal: true

require "rails_helper"

RSpec.describe AdminBlockedIpsController, type: :controller do
  let(:admin_user) { create(:user, admin: true) }

  before do
    Rails.cache.clear
    # Mock authentication
    allow(controller).to receive(:login_required).and_return(true)
    allow(controller).to receive(:logged_in?).and_return(true)
    allow(controller).to receive(:current_user).and_return(admin_user)
    allow(controller).to receive(:admin_required).and_return(true)
  end

  describe "GET #index" do
    it "renders successfully" do
      get :index
      expect(response).to be_successful
    end

    it "handles search query parameter" do
      get :index, params: { query: "192.168" }
      expect(response).to be_successful
    end

    it "handles pagination parameter" do
      get :index, params: { page: 2 }
      expect(response).to be_successful
    end
  end

  describe "POST #unblock" do
    let(:blocked_ip) { "192.168.1.100" }

    before do
      # Block an IP
      tracker = SMTPServer::AuthFailureTracker.new(ip_address: blocked_ip, threshold: 3)
      3.times { tracker.record_failure }
      tracker.block_ip
    end

    it "unblocks the specified IP" do
      expect(SMTPServer::AuthFailureTracker.blocked?(blocked_ip)).to be true

      post :unblock, params: { ip: blocked_ip }

      expect(SMTPServer::AuthFailureTracker.blocked?(blocked_ip)).to be false
      expect(flash[:notice]).to include("unblocked successfully")
      expect(response).to redirect_to(admin_blocked_ips_path)
    end

    it "shows error for missing IP parameter" do
      post :unblock, params: { ip: "" }

      expect(flash[:error]).to include("IP address is required")
      expect(response).to redirect_to(admin_blocked_ips_path)
    end
  end

  describe "POST #unblock_all" do
    before do
      # Block multiple IPs
      3.times do |i|
        ip = "192.168.1.#{100 + i}"
        tracker = SMTPServer::AuthFailureTracker.new(ip_address: ip, threshold: 3)
        3.times { tracker.record_failure }
        tracker.block_ip
      end
    end

    it "unblocks all IPs" do
      expect(SMTPServer::AuthFailureTracker.all_blocked.size).to eq(3)

      post :unblock_all

      expect(SMTPServer::AuthFailureTracker.all_blocked.size).to eq(0)
      expect(flash[:notice]).to include("Successfully unblocked 3 IP address")
      expect(response).to redirect_to(admin_blocked_ips_path)
    end
  end

  describe "POST #cleanup" do
    before do
      # Block an IP
      tracker = SMTPServer::AuthFailureTracker.new(ip_address: "192.168.1.100", threshold: 3)
      3.times { tracker.record_failure }
      tracker.block_ip

      # Add expired entry to index (manually add IP without actual block)
      index = Rails.cache.read(SMTPServer::AuthFailureTracker.blocked_index_key) || []
      index << "10.0.0.1" # This IP is not actually blocked
      Rails.cache.write(SMTPServer::AuthFailureTracker.blocked_index_key, index)
    end

    it "cleans up expired entries" do
      post :cleanup

      expect(flash[:notice]).to match(/Cleaned up \d+ expired/)
      expect(response).to redirect_to(admin_blocked_ips_path)
    end
  end
end
