# frozen_string_literal: true

RSpec.describe PayoutRouter::Domain::Provider do
  describe "#bank_allowed?" do
    it "пропускает любой банк, когда список пуст" do
      expect(build_provider(banks: []).bank_allowed?("gazprombank")).to be(true)
    end

    it "пропускает только банки из списка" do
      provider = build_provider(banks: %w[sberbank vtb])
      expect(provider.bank_allowed?("sberbank")).to be(true)
      expect(provider.bank_allowed?("alfa")).to be(false)
    end

    it "трактует список как исключения при exclude_banks" do
      provider = build_provider(banks: %w[sberbank], exclude_banks: true)
      expect(provider.bank_allowed?("sberbank")).to be(false)
      expect(provider.bank_allowed?("alfa")).to be(true)
    end
  end

  describe "#negative_margin?" do
    it "истинно, когда маржа провайдера выше маржи мерчанта без соглашения" do
      expect(build_provider(provider_margin_pct: 2.0, merchant_margin_pct: 1.5).negative_margin?).to be(true)
    end

    it "ложно при allow_negative_agreement" do
      provider = build_provider(provider_margin_pct: 2.0, merchant_margin_pct: 1.5, allow_negative_agreement: true)
      expect(provider.negative_margin?).to be(false)
    end
  end

  it "подставляет долю по количеству как цель по объёму, если та не задана" do
    expect(build_provider(traffic_percentage: 35).volume_target_pct).to eq(35)
    expect(build_provider(traffic_percentage: 35, volume_share_pct: 50).volume_target_pct).to eq(50)
  end
end
