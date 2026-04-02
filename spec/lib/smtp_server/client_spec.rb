# frozen_string_literal: true

require "rails_helper"

module SMTPServer

  describe Client do
    let(:ip_address) { "1.2.3.4" }
    subject(:client) { described_class.new(ip_address) }

    describe "initialization" do
      it "defaults submission? to false" do
        expect(client.submission?).to eq false
      end

      it "defaults @tls to false" do
        expect(client.instance_variable_get(:@tls)).to eq false
      end

      context "with submission: true" do
        subject(:client) { described_class.new(ip_address, submission: true) }

        it "sets submission? to true" do
          expect(client.submission?).to eq true
        end
      end

      context "with tls: true" do
        subject(:client) { described_class.new(ip_address, tls: true) }

        it "sets @tls to true immediately" do
          expect(client.instance_variable_get(:@tls)).to eq true
        end
      end
    end
  end

end
