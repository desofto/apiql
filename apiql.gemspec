# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |spec|
  spec.name          = 'apiql'
  spec.version       = '0.1.3'
  spec.authors       = ['Dmitry Silchenko']
  spec.email         = ['dmitry@desofto.com']

  spec.summary       = 'Implementation of the API language similar to GraphQL for Ruby on Rails'
  spec.description   = 'Implementation of the API language similar to GraphQL for Ruby on Rails'
  spec.homepage      = 'https://github.com/desofto/apiql'
  spec.license       = 'MIT'

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.bindir        = 'exe'
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_development_dependency 'bundler', '~> 1.11'
  spec.add_development_dependency 'rake', '~> 11.0'
  spec.add_development_dependency 'pry', '~> 0.10'
end
