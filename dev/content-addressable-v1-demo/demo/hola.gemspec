Gem::Specification.new do |s|
  s.name        = "hola"
  s.version     = "1.0.0"
  s.summary     = "content-addressable native gem demo"
  s.authors     = ["poc"]
  s.files       = Dir["lib/**/*.rb"] + Dir["ext/**/*"]
  s.extensions  = ["ext/hola/extconf.rb"]
  # Pin to a single Ruby ABI (the Ruby building this gem) so it is a "skinny"
  # binary -> content-addressable. Computed at build time so the demo is skinny
  # for whatever Ruby you run it with, not just 3.3.
  minor = RUBY_VERSION.split(".").first(2).join(".")
  s.required_ruby_version = "~> #{minor}.0"
end
