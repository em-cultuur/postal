# frozen_string_literal: true

require "rails_helper"

module SMTPServer

  describe Client do
    let(:ip_address) { "1.2.3.4" }
    subject(:client) { described_class.new(ip_address) }

    describe "HELO" do
      it "returns the hostname" do
        expect(client.state).to eq :welcome
        expect(client.handle("HELO: test.example.com")).to eq "250 #{Postal::Config.postal.smtp_hostname}"
        expect(client.state).to eq :welcomed
      end
    end

    describe "EHLO" do
      it "returns the capabilities" do
        expect(client.handle("EHLO test.example.com")).to eq ["250-My capabilities are",
                                                              "250 AUTH CRAM-MD5 PLAIN LOGIN",]
      end

      context "when TLS is enabled" do
        it "returns capabilities include starttls" do
          allow(Postal::Config.smtp_server).to receive(:tls_enabled?).and_return(true)
          expect(client.handle("EHLO test.example.com")).to eq ["250-My capabilities are",
                                                                "250-STARTTLS",
                                                                "250 AUTH CRAM-MD5 PLAIN LOGIN",]
        end
      end

      context "when already on TLS (port 465)" do
        subject(:client) { described_class.new(ip_address, tls: true) }

        it "does not advertise STARTTLS" do
          allow(Postal::Config.smtp_server).to receive(:tls_enabled?).and_return(true)
          expect(client.handle("EHLO test.example.com")).to eq ["250-My capabilities are",
                                                                "250 AUTH CRAM-MD5 PLAIN LOGIN",]
        end
      end

      context "on submission port (port 587)" do
        subject(:client) { described_class.new(ip_address, submission: true) }

        it "advertises STARTTLS when TLS is enabled" do
          allow(Postal::Config.smtp_server).to receive(:tls_enabled?).and_return(true)
          expect(client.handle("EHLO test.example.com")).to eq ["250-My capabilities are",
                                                                "250-STARTTLS",
                                                                "250 AUTH CRAM-MD5 PLAIN LOGIN",]
        end
      end
    end

    describe "STARTTLS" do
      context "when TLS is already active" do
        subject(:client) { described_class.new(ip_address, tls: true) }

        it "returns an error" do
          expect(client.handle("STARTTLS")).to eq "503 TLS already active"
        end
      end

      context "on submission port without TLS" do
        subject(:client) { described_class.new(ip_address, submission: true) }

        it "returns 220 Ready when TLS is enabled" do
          allow(Postal::Config.smtp_server).to receive(:tls_enabled?).and_return(true)
          expect(client.handle("STARTTLS")).to eq "220 Ready to start TLS"
        end
      end

      context "when TLS is not enabled on the server" do
        it "returns 454 TLS not available" do
          allow(Postal::Config.smtp_server).to receive(:tls_enabled?).and_return(false)
          expect(client.handle("STARTTLS")).to eq "454 TLS not available"
        end
      end
    end
  end

end
