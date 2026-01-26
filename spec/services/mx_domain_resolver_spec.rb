# frozen_string_literal: true

require "rails_helper"

describe MXDomainResolver do
  subject(:resolver) { described_class.new(recipient_domain: recipient_domain) }

  let(:recipient_domain) { "example.com" }

  describe ".resolve" do
    it "resolves MX domain for a recipient domain" do
      result = described_class.resolve("example.com")
      expect(result).to be_a(String)
    end
  end

  describe "#call" do
    context "when recipient domain is blank" do
      let(:recipient_domain) { nil }

      it "returns nil" do
        expect(resolver.call).to be_nil
      end
    end

    context "when domain is cached and not expired" do
      let!(:cache) { create(:mx_domain_cache, recipient_domain: recipient_domain, mx_domain: "google.com", expires_at: 1.hour.from_now) }

      it "returns cached mx_domain" do
        expect(resolver.call).to eq("google.com")
      end

      it "does not perform DNS lookup" do
        expect(Resolv::DNS).not_to receive(:new)
        resolver.call
      end
    end

    context "when domain is cached but expired" do
      let!(:cache) { create(:mx_domain_cache, :expired, recipient_domain: recipient_domain, mx_domain: "old-domain.com") }

      it "performs new DNS lookup" do
        # Mock DNS resolution
        dns = instance_double(Resolv::DNS)
        exchange = instance_double("Resolv::DNS::Name")
        allow(exchange).to receive(:to_s).and_return("mx1.example.com")
        mx_record = instance_double(Resolv::DNS::Resource::IN::MX, preference: 10, exchange: exchange)
        allow(Resolv::DNS).to receive(:new).and_return(dns)
        allow(dns).to receive(:getresources).with(recipient_domain, Resolv::DNS::Resource::IN::MX).and_return([mx_record])
        allow(dns).to receive(:close)

        result = resolver.call
        expect(result).to eq("example.com")
      end
    end

    context "when no cache exists" do
      it "performs DNS lookup and caches result" do
        # Mock DNS resolution
        dns = instance_double(Resolv::DNS)
        exchange = instance_double("Resolv::DNS::Name")
        allow(exchange).to receive(:to_s).and_return("mx1.google.com")
        mx_record = instance_double(Resolv::DNS::Resource::IN::MX, preference: 10, exchange: exchange)
        allow(Resolv::DNS).to receive(:new).and_return(dns)
        allow(dns).to receive(:getresources).with(recipient_domain, Resolv::DNS::Resource::IN::MX).and_return([mx_record])
        allow(dns).to receive(:close)

        result = resolver.call
        expect(result).to eq("google.com")

        # Check cache was created
        cache = MXDomainCache.find_by(recipient_domain: recipient_domain)
        expect(cache).to be_present
        expect(cache.mx_domain).to eq("google.com")
        expect(cache.expires_at).to be > Time.current
      end

      it "selects primary MX (lowest preference)" do
        dns = instance_double(Resolv::DNS)

        exchange1 = instance_double("Resolv::DNS::Name")
        allow(exchange1).to receive(:to_s).and_return("mx2.google.com")
        mx1 = instance_double(Resolv::DNS::Resource::IN::MX, preference: 20, exchange: exchange1)

        exchange2 = instance_double("Resolv::DNS::Name")
        allow(exchange2).to receive(:to_s).and_return("mx1.google.com")
        mx2 = instance_double(Resolv::DNS::Resource::IN::MX, preference: 10, exchange: exchange2)

        exchange3 = instance_double("Resolv::DNS::Name")
        allow(exchange3).to receive(:to_s).and_return("mx3.google.com")
        mx3 = instance_double(Resolv::DNS::Resource::IN::MX, preference: 30, exchange: exchange3)

        allow(Resolv::DNS).to receive(:new).and_return(dns)
        allow(dns).to receive(:getresources).with(recipient_domain, Resolv::DNS::Resource::IN::MX).and_return([mx1, mx2, mx3])
        allow(dns).to receive(:close)

        result = resolver.call
        expect(result).to eq("google.com") # From mx1.google.com (preference 10)
      end
    end

    context "when DNS resolution fails" do
      it "returns recipient domain as fallback" do
        allow(Resolv::DNS).to receive(:new).and_raise(StandardError.new("DNS error"))

        result = resolver.call
        expect(result).to eq(recipient_domain)
      end
    end

    context "when no MX records found" do
      it "returns nil" do
        dns = instance_double(Resolv::DNS)
        allow(Resolv::DNS).to receive(:new).and_return(dns)
        allow(dns).to receive(:getresources).with(recipient_domain, Resolv::DNS::Resource::IN::MX).and_return([])
        allow(dns).to receive(:close)

        result = resolver.call
        expect(result).to be_nil
      end
    end
  end

  describe "#extract_main_domain" do
    it "extracts main domain from simple MX hostname" do
      result = resolver.send(:extract_main_domain, "mx1.example.com")
      expect(result).to eq("example.com")
    end

    it "extracts main domain from complex MX hostname" do
      result = resolver.send(:extract_main_domain, "gmail-smtp-in.l.google.com")
      expect(result).to eq("google.com")
    end

    it "removes trailing dot" do
      result = resolver.send(:extract_main_domain, "mx1.example.com.")
      expect(result).to eq("example.com")
    end

    it "handles single-part hostname" do
      result = resolver.send(:extract_main_domain, "localhost")
      expect(result).to eq("localhost")
    end
  end

  describe "#cache_mx_domain" do
    it "creates new cache entry" do
      expect do
        resolver.send(:cache_mx_domain, "google.com")
      end.to change(MXDomainCache, :count).by(1)

      cache = MXDomainCache.find_by(recipient_domain: recipient_domain)
      expect(cache.mx_domain).to eq("google.com")
      expect(cache.expires_at).to be_within(1.second).of(1.hour.from_now)
    end

    it "updates existing cache entry" do
      existing = create(:mx_domain_cache, recipient_domain: recipient_domain, mx_domain: "old.com")

      expect do
        resolver.send(:cache_mx_domain, "new.com")
      end.not_to change(MXDomainCache, :count)

      existing.reload
      expect(existing.mx_domain).to eq("new.com")
    end
  end
end
