# frozen_string_literal: true

require "rails_helper"

module SMTPServer

  describe Client do
    let(:ip_address) { "1.2.3.4" }
    subject(:client) { described_class.new(ip_address) }

    describe "on submission port" do
      subject(:client) { described_class.new(ip_address, submission: true) }

      before do
        client.handle("HELO test.example.com")
      end

      context "without TLS" do
        it "rejects MAIL FROM" do
          expect(client.handle("MAIL FROM: test@example.com")).to eq "530 5.7.0 Must issue a STARTTLS command first"
        end
      end

      context "with TLS active but without authentication" do
        subject(:client) { described_class.new(ip_address, submission: true, tls: true) }

        it "rejects MAIL FROM" do
          expect(client.handle("MAIL FROM: test@example.com")).to eq "530 5.7.1 Authentication required"
        end
      end

      context "with TLS active and authenticated" do
        subject(:client) { described_class.new(ip_address, submission: true, tls: true) }

        it "accepts MAIL FROM" do
          credential = create(:credential, type: "SMTP")
          allow(Postal::Config.smtp_server).to receive(:tls_enabled?).and_return(true)
          client.handle("EHLO test.example.com")
          client.handle("AUTH PLAIN #{credential.to_smtp_plain}")
          expect(client.handle("MAIL FROM: test@example.com")).to eq "250 OK"
        end
      end
    end

    describe "on port 465 (implicit TLS, no mandatory auth)" do
      subject(:client) { described_class.new(ip_address, tls: true) }

      before do
        client.handle("HELO test.example.com")
      end

      it "accepts MAIL FROM without authentication" do
        expect(client.handle("MAIL FROM: test@example.com")).to eq "250 OK"
      end
    end

    describe "MAIL FROM" do
      it "returns an error if no HELO is provided" do
        expect(client.handle("MAIL FROM: test@example.com")).to eq "503 EHLO/HELO first please"
        expect(client.state).to eq :welcome
      end

      it "resets the transaction when called" do
        expect(client).to receive(:transaction_reset).and_call_original.at_least(3).times
        client.handle("HELO test.example.com")
        client.handle("MAIL FROM: test@example.com")
        client.handle("MAIL FROM: test2@example.com")
      end

      it "sets the mail from address" do
        client.handle("HELO test.example.com")
        expect(client.handle("MAIL FROM: test@example.com")).to eq "250 OK"
        expect(client.state).to eq :mail_from_received
        expect(client.instance_variable_get("@mail_from")).to eq "test@example.com"
      end
    end
  end

end
