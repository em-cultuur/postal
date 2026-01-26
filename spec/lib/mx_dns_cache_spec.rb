# frozen_string_literal: true

require "rails_helper"

describe MXDNSCache do
  let(:resolver) { double("DNSResolver") }
  let(:test_domain) { "example.com" }
  let(:test_records) { [[10, "mail.example.com"], [20, "mail2.example.com"]] }

  before do
    # Clear cache before each test
    described_class.clear_all
    allow(resolver).to receive(:mx).and_return(test_records)
  end

  describe ".mx_records" do
    it "returns MX records from resolver" do
      records = described_class.mx_records(test_domain, resolver)
      expect(records).to eq(test_records)
      expect(resolver).to have_received(:mx).once
    end

    it "caches results on subsequent calls" do
      described_class.mx_records(test_domain, resolver)
      described_class.mx_records(test_domain, resolver)

      expect(resolver).to have_received(:mx).once
    end

    it "respects TTL expiration" do
      described_class.mx_records(test_domain, resolver, ttl: -1)
      described_class.mx_records(test_domain, resolver)

      expect(resolver).to have_received(:mx).twice
    end

    it "handles resolver errors gracefully" do
      allow(resolver).to receive(:mx).and_raise(StandardError.new("DNS failure"))

      expect do
        described_class.mx_records(test_domain, resolver)
      end.to raise_error(StandardError, "DNS failure")

      # Error should be cached briefly
      allow(resolver).to receive(:mx).and_return(test_records)
      records = described_class.mx_records(test_domain, resolver)
      expect(records).to eq([]) # Empty array from cached error
    end

    it "normalizes domain to lowercase" do
      described_class.mx_records("EXAMPLE.COM", resolver)
      described_class.mx_records("example.com", resolver)

      expect(resolver).to have_received(:mx).once
    end
  end

  describe ".primary_mx" do
    it "returns the primary MX record" do
      primary = described_class.primary_mx(test_domain, resolver)
      expect(primary).to eq("mail.example.com")
    end

    it "returns nil when no records exist" do
      allow(resolver).to receive(:mx).and_return([])

      primary = described_class.primary_mx(test_domain, resolver)
      expect(primary).to be_nil
    end

    it "caches results" do
      described_class.primary_mx(test_domain, resolver)
      described_class.primary_mx(test_domain, resolver)

      expect(resolver).to have_received(:mx).once
    end
  end

  describe ".clear" do
    it "removes domain from cache" do
      described_class.mx_records(test_domain, resolver)
      expect(resolver).to have_received(:mx).once

      expect(described_class.clear(test_domain)).to be true

      allow(resolver).to receive(:mx).and_return(test_records)
      described_class.mx_records(test_domain, resolver)

      expect(resolver).to have_received(:mx).twice
    end

    it "returns false for non-cached domain" do
      expect(described_class.clear("non-existent.com")).to be false
    end
  end

  describe ".clear_all" do
    it "clears entire cache" do
      described_class.mx_records("domain1.com", resolver)
      described_class.mx_records("domain2.com", resolver)

      expect(described_class.clear_all).to eq(2)

      allow(resolver).to receive(:mx).and_return(test_records)
      described_class.mx_records("domain1.com", resolver)

      expect(resolver).to have_received(:mx).at_least(3).times
    end
  end

  describe ".stats" do
    it "returns cache statistics" do
      described_class.mx_records(test_domain, resolver)

      stats = described_class.stats
      expect(stats[:size]).to eq(1)
      expect(stats[:entries]).to be_an(Array)
      expect(stats[:entries].first[:domain]).to eq("example.com")
      expect(stats[:entries].first[:expired]).to be false
    end

    it "shows expired entries" do
      described_class.mx_records(test_domain, resolver, ttl: -1)

      stats = described_class.stats
      expect(stats[:entries].first[:expired]).to be true
    end

    it "shows error entries" do
      allow(resolver).to receive(:mx).and_raise(StandardError.new("DNS failure"))
      expect { described_class.mx_records(test_domain, resolver) }.to raise_error(StandardError)

      stats = described_class.stats
      expect(stats[:entries].first[:has_error]).to be true
    end
  end

  describe "thread safety" do
    it "handles concurrent cache access" do
      threads = []
      results = []

      5.times do |i|
        threads << Thread.new do
          records = described_class.mx_records("domain#{i}.com", resolver)
          results << records
        end
      end

      threads.each(&:join)

      expect(results).to all(eq(test_records))
      expect(resolver).to have_received(:mx).at_least(1).times
    end
  end
end
