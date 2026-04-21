#!/usr/bin/env ruby
require "bundler/setup"
require "ruby_llm"
require "net/http"
require "json"
require "uri"
require "dotenv/load"

RubyLLM.configure do |config|
  config.openrouter_api_key = ENV.fetch("OPENROUTER_API_KEY")
end

class Weather < RubyLLM::Tool
  GEOCODE_URL = "https://geocoding-api.open-meteo.com/v1/search"
  FORECAST_URL = "https://api.open-meteo.com/v1/forecast"
  CURRENT_FIELDS = "temperature_2m,wind_speed_10m,relative_humidity_2m,weather_code"

  description "Get the current weather for a place by name (city, landmark, etc.)."
  param :location, desc: "Name of the place, e.g. 'Paris' or 'Paris, France'."

  def execute(location:)
    place = geocode(location)
    return { error: "no location found for #{location.inspect}" } unless place

    format_current(place, fetch_current(place))
  rescue => error
    { error: error.message }
  end

  private

  def geocode(name)
    get_json(GEOCODE_URL, name: name, count: 1, language: "en", format: "json")
      .dig("results", 0)
  end

  def fetch_current(place)
    get_json(FORECAST_URL,
             latitude: place["latitude"],
             longitude: place["longitude"],
             current: CURRENT_FIELDS).fetch("current")
  end

  def format_current(place, current)
    {
      location: [place["name"], place["admin1"], place["country"]].compact.join(", "),
      temperature_c: current["temperature_2m"],
      humidity_pct: current["relative_humidity_2m"],
      wind_kmh: current["wind_speed_10m"],
      weather_code: current["weather_code"],
      observed_at: current["time"]
    }
  end

  def get_json(base, **params)
    uri = URI(base)
    uri.query = URI.encode_www_form(params)
    JSON.parse(Net::HTTP.get(uri))
  end
end

SYSTEM_PROMPT = <<~PROMPT
  You are a terminal assistant. Use the Weather tool whenever the user asks
  about current weather, temperature, wind, or humidity for a place. Keep
  answers concise.
PROMPT

def build_chat
  RubyLLM
    .chat(model: ENV.fetch("LLM_DEFAULT_MODEL"))
    .with_instructions(SYSTEM_PROMPT)
    .with_tools(Weather)
end

def run_repl(chat)
  puts "ruby AI agent — type 'exit' or Ctrl-D to quit"

  loop do
    print "\n> "
    input = $stdin.gets
    break if input.nil?
    msg = input.strip
    next if msg.empty?
    break if %w[exit quit].include?(msg)

    begin
      chat.ask(msg) { |chunk| print chunk.content }
      puts
    rescue Interrupt
      puts "\n[interrupted]"
    rescue => error
      warn "\n[error] #{error.class}: #{error.message}"
    end
  end
end

run_repl(build_chat)
