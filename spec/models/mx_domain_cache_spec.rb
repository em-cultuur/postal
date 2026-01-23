# frozen_string_literal: true

require "rails_helper"

RSpec.describe MXDomainCache do
  describe "validations" do
    it "requires recipient_domain" do
      cache = MXDomainCache.new(mx_domain: "google.com", resolved_at: Time.current, expires_at: 1.hour.from_now)
      expect(cache).not_to be_valid
      expect(cache.errors[:recipient_domain]).to include("can't be blank")
    end

    it "requires mx_domain" do
      cache = MXDomainCache.new(recipient_domain: "gmail.com", resolved_at: Time.current, expires_at: 1.hour.from_now)
      expect(cache).not_to be_valid
      expect(cache.errors[:mx_domain]).to include("can't be blank")
    end

    it "enforces uniqueness of recipient_domain" do
      MXDomainCache.create!(
        recipient_domain: "gmail.com",
        mx_domain: "google.com",
        resolved_at: Time.current,
        expires_at: 1.hour.from_now
      )
      duplicate = MXDomainCache.new(
        recipient_domain: "gmail.com",
        mx_domain: "google.com",
        resolved_at: Time.current,
        expires_at: 1.hour.from_now
      )
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:recipient_domain]).to include("has already been taken")
    end
  end

  describe ".resolve" do
    it "returns cached mx_domain when cache is valid" do
      cache = create(:mx_domain_cache, recipient_domain: "gmail.com", mx_domain: "google.com")
      expect(MXDomainCache.resolve("gmail.com")).to eq("google.com")
    end

    it "normalizes recipient_domain to lowercase" do
      cache = create(:mx_domain_cache, recipient_domain: "gmail.com", mx_domain: "google.com")
      expect(MXDomainCache.resolve("GMAIL.COM")).to eq("google.com")
    end

    it "returns nil when cache has expired" do
      cache = create(:mx_domain_cache, :expired, recipient_domain: "gmail.com")
      expect(MXDomainCache.resolve("gmail.com")).to be_nil
    end

    it "returns nil when no cache entry exists" do
      expect(MXDomainCache.resolve("nonexistent.com")).to be_nil
    end

    it "returns nil when recipient_domain is blank" do
      expect(MXDomainCache.resolve("")).to be_nil
      expect(MXDomainCache.resolve(nil)).to be_nil
    end
  end

  describe ".cleanup_expired" do
    it "deletes expired cache entries" do
      expired1 = create(:mx_domain_cache, recipient_domain: "expired1.com", expires_at: 1.hour.ago)
      expired2 = create(:mx_domain_cache, recipient_domain: "expired2.com", expires_at: 2.hours.ago)
      valid = create(:mx_domain_cache, recipient_domain: "valid.com", expires_at: 1.hour.from_now)

      deleted_count = MXDomainCache.cleanup_expired

      expect(deleted_count).to eq(2)
      expect(MXDomainCache.exists?(expired1.id)).to be false
      expect(MXDomainCache.exists?(expired2.id)).to be false
      expect(MXDomainCache.exists?(valid.id)).to be true
    end

    it "returns 0 when no expired entries exist" do
      create(:mx_domain_cache, expires_at: 1.hour.from_now)
      expect(MXDomainCache.cleanup_expired).to eq(0)
    end
  end

  describe "#expired?" do
    it "returns true when expires_at is in the past" do
      cache = MXDomainCache.new(expires_at: 1.hour.ago)
      expect(cache.expired?).to be true
    end

    it "returns false when expires_at is in the future" do
      cache = MXDomainCache.new(expires_at: 1.hour.from_now)
      expect(cache.expired?).to be false
    end
  end

  describe "scopes" do
    before do
      @expired1 = create(:mx_domain_cache, recipient_domain: "expired1.com", expires_at: 1.hour.ago)
      @expired2 = create(:mx_domain_cache, recipient_domain: "expired2.com", expires_at: 2.hours.ago)
      @valid1 = create(:mx_domain_cache, recipient_domain: "valid1.com", expires_at: 1.hour.from_now)
      @valid2 = create(:mx_domain_cache, recipient_domain: "valid2.com", expires_at: 2.hours.from_now)
    end

    describe ".expired" do
      it "returns only expired cache entries" do
        expect(MXDomainCache.expired).to contain_exactly(@expired1, @expired2)
      end
    end
  end
end
