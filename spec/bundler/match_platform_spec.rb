# frozen_string_literal: true

require "bundler/match_platform"

RSpec.describe Bundler::MatchPlatform do
  describe ".prefer_content_addressable" do
    def skinny(ruby_ok:)
      double(:skinny, content_addressable?: true, matches_current_ruby?: ruby_ok)
    end

    def regular
      double(:regular, content_addressable?: false)
    end

    context "with no content-addressable specs" do
      it "returns the candidates unchanged" do
        fat = regular
        expect(described_class.prefer_content_addressable([fat])).to eq([fat])
      end
    end

    context "with a Ruby-compatible skinny spec alongside a fat spec" do
      it "prefers the skinny spec exclusively" do
        sk = skinny(ruby_ok: true)
        expect(described_class.prefer_content_addressable([regular, sk])).to eq([sk])
      end
    end

    context "with several skinny ABI variants where only one matches the running Ruby" do
      it "keeps only the compatible skinny spec" do
        compatible = skinny(ruby_ok: true)
        candidates = [skinny(ruby_ok: false), compatible, skinny(ruby_ok: false), regular]
        expect(described_class.prefer_content_addressable(candidates)).to eq([compatible])
      end
    end

    context "when no skinny spec matches the running Ruby" do
      it "falls back to the regular (fat/source) specs" do
        fat = regular
        candidates = [skinny(ruby_ok: false), skinny(ruby_ok: false), fat]
        expect(described_class.prefer_content_addressable(candidates)).to eq([fat])
      end
    end
  end

  describe "content-addressable defaults" do
    let(:spec_class) do
      Class.new do
        include Bundler::MatchPlatform
      end
    end

    it "defaults content_addressable? to false for specs that don't override it" do
      expect(spec_class.new).not_to be_content_addressable
    end

    it "defaults content_address to nil for specs that don't override it" do
      expect(spec_class.new.content_address).to be_nil
    end
  end
end
