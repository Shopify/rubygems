Gem::Specification.new do |s|
  s.name        = "hola"
  s.version     = "1.0.0"
  s.summary     = "content-addressable native gem demo"
  s.authors     = ["poc"]
  s.files       = Dir["lib/**/*.rb"] + Dir["ext/**/*"]
  s.extensions  = ["ext/hola/extconf.rb"]
  # A single Ruby ABI makes this a "skinny" binary -> content-addressable.
  s.required_ruby_version = "~> 3.3.0"
end
