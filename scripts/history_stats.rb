#!/usr/bin/env ruby
# frozen_string_literal: true

# Калибровка по истории: считает по operations_history.csv фактические доли
# count/volume, конверсию и латентность каждого провайдера и сравнивает их
# с заявленными в providers.json traffic_percentage / conversion_24h.
#
#   ruby scripts/history_stats.rb                 # человекочитаемая сводка
#   ruby scripts/history_stats.rb --json          # + data/derived/history_stats.json

require "csv"
require "fileutils"
require "json"

DATA_DIR = File.expand_path("../data", __dir__)
DERIVED_DIR = File.join(DATA_DIR, "derived")
HISTORY = File.join(DATA_DIR, "operations_history.csv")
PROVIDERS = File.join(DATA_DIR, "providers.json")

AMOUNT_BUCKETS = [
  ["<= 1 000", 0, 1_000],
  ["1 001 - 50 000", 1_001, 50_000],
  ["50 001 - 100 000", 50_001, 100_000],
  ["> 100 000", 100_001, Float::INFINITY]
].freeze

STATUSES = %w[approved rejected expired].freeze

def pct(part, whole)
  return 0.0 if whole.to_f.zero?

  ((part.to_f / whole) * 1000).round / 10.0
end

def avg(values)
  return nil if values.empty?

  (values.sum.to_f / values.size).round(1)
end

def conversion(rows)
  (rows.count { |r| r[:status] == "approved" }.to_f / rows.size).round(4)
end

def load_rows
  CSV.read(HISTORY, headers: true).map do |row|
    {
      operation_id: row["operation_id"],
      created_at: row["created_at"],
      amount: row["amount"].to_i,
      bank: row["bank"],
      provider: row["payment_system"],
      status: row["status"],
      latency_sec: row["latency_sec"].to_i
    }
  end
end

def bucket_for(amount)
  AMOUNT_BUCKETS.find { |(_, from, to)| amount.between?(from, to) }&.first
end

def status_counts(rows)
  STATUSES.to_h { |status| [status, rows.count { |r| r[:status] == status }] }
end

def tally_desc(values)
  values.tally.sort_by { |_, count| -count }.to_h
end

def provider_stats(rows, totals, declared)
  amounts = rows.map { |r| r[:amount] }
  volume = amounts.sum

  {
    "count" => rows.size,
    "count_share_pct" => pct(rows.size, totals[:count]),
    "target_traffic_pct" => declared&.dig("traffic_percentage"),
    "volume" => volume,
    "volume_share_pct" => pct(volume, totals[:volume]),
    "statuses" => status_counts(rows),
    "conversion" => conversion(rows),
    "declared_conversion_24h" => declared&.dig("conversion_24h")
  }.merge(provider_shape(rows, amounts))
end

# Вторая половина карточки провайдера: латентность, разброс сумм, банки.
def provider_shape(rows, amounts)
  approved = rows.select { |r| r[:status] == "approved" }

  {
    "avg_latency_sec" => avg(rows.map { |r| r[:latency_sec] }),
    "avg_latency_sec_approved" => avg(approved.map { |r| r[:latency_sec] }),
    "amount_min" => amounts.min,
    "amount_max" => amounts.max,
    "amount_avg" => avg(amounts),
    "banks_seen" => tally_desc(rows.map { |r| r[:bank] }),
    "conversion_by_bank" => conversion_by_bank(rows)
  }
end

def conversion_by_bank(rows)
  by_bank = rows.group_by { |r| r[:bank] }.transform_values do |bank_rows|
    { "count" => bank_rows.size, "conversion" => conversion(bank_rows) }
  end
  by_bank.sort_by { |_, stats| -stats["count"] }.to_h
end

def providers_section(rows, totals, declared)
  by_provider = rows.group_by { |r| r[:provider] }.sort_by { |_, provider_rows| -provider_rows.size }
  by_provider.to_h do |provider, provider_rows|
    [provider, provider_stats(provider_rows, totals, declared[provider])]
  end
end

def amount_bucket_stats(rows)
  AMOUNT_BUCKETS.to_h do |(label, _from, _to)|
    bucket_rows = rows.select { |r| bucket_for(r[:amount]) == label }
    stats = if bucket_rows.empty?
              { "count" => 0 }
            else
              {
                "count" => bucket_rows.size,
                "conversion" => conversion(bucket_rows),
                "providers" => tally_desc(bucket_rows.map { |r| r[:provider] })
              }
            end
    [label, stats]
  end
end

def build_stats(rows, providers)
  totals = { count: rows.size, volume: rows.sum { |r| r[:amount] } }
  declared = providers.to_h { |p| [p["payment_system"], p] }

  {
    "source" => "data/operations_history.csv",
    "generated_by" => "scripts/history_stats.rb",
    "total_operations" => totals[:count],
    "total_volume" => totals[:volume],
    "period" => rows.map { |r| r[:created_at][0, 10] }.minmax.uniq.join(" .. "),
    "statuses" => status_counts(rows),
    "overall_conversion" => conversion(rows),
    "providers" => providers_section(rows, totals, declared),
    "banks" => conversion_by_bank(rows),
    "amount_buckets" => amount_bucket_stats(rows),
    "providers_without_history" => declared.keys - rows.map { |r| r[:provider] }.uniq
  }
end

def print_header(stats)
  statuses = stats["statuses"].map { |name, count| "#{name}=#{count}" }.join(", ")
  puts "=== История роутинга: #{stats["total_operations"]} операций за #{stats["period"]} ==="
  puts "Объём: #{stats["total_volume"]} ₽, общая конверсия: #{(stats["overall_conversion"] * 100).round(1)}%"
  puts "Статусы: #{statuses}"
  puts
end

def print_providers(stats)
  printf("%-14s %6s %8s %8s %12s %8s %11s %9s\n",
         "provider", "count", "count%", "target%", "volume", "vol%", "conv(факт)", "conv_24h")
  stats["providers"].each do |name, p|
    printf("%-14s %6d %7.1f%% %7s%% %12d %7.1f%% %10.1f%% %9s\n",
           name, p["count"], p["count_share_pct"], p["target_traffic_pct"] || "-",
           p["volume"], p["volume_share_pct"], p["conversion"] * 100,
           p["declared_conversion_24h"] || "-")
  end
  puts
end

def print_buckets(stats)
  orphans = stats["providers_without_history"]
  puts "Без истории: #{orphans.join(", ")}" if orphans.any?
  puts "Конверсия по сумме чека:"
  stats["amount_buckets"].each do |label, bucket|
    next if bucket["count"].zero?

    puts "  #{label.ljust(18)} n=#{bucket["count"].to_s.ljust(4)} conv=#{(bucket["conversion"] * 100).round(1)}%"
  end
end

# --- main ---

rows = load_rows
providers = JSON.parse(File.read(PROVIDERS))["providers"]
stats = build_stats(rows, providers)

print_header(stats)
print_providers(stats)
print_buckets(stats)

if ARGV.include?("--json")
  FileUtils.mkdir_p(DERIVED_DIR)
  out = File.join(DERIVED_DIR, "history_stats.json")
  File.write(out, "#{JSON.pretty_generate(stats)}\n")
  puts
  puts "JSON: #{out}"
end
