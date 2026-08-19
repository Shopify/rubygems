# frozen_string_literal: true

require_relative "helper"
require "rubygems/commands/info_command"

class TestGemCommandsInfoCommand < Gem::TestCase
  def setup
    super

    @cmd = Gem::Commands::InfoCommand.new
  end

  def gem(name, version = "1.0")
    spec = quick_gem name do |gem|
      gem.summary = "test gem"
      gem.homepage = "https://github.com/ruby/rubygems"
      gem.files = %W[lib/#{name}.rb Rakefile]
      gem.authors = ["Colby", "Jack"]
      gem.license = "MIT"
      gem.version = version
    end
    write_file File.join(*%W[gems #{spec.full_name} lib #{name}.rb])
    write_file File.join(*%W[gems #{spec.full_name} Rakefile])
    spec
  end

  def test_execute
    @gem = gem "foo", "1.0.0"

    @cmd.handle_options %w[foo]

    use_ui @ui do
      @cmd.execute
    end

    assert_include(@ui.output, "#{@gem.name} (#{@gem.version})\n")
    assert_include(@ui.output, "Authors: #{@gem.authors.join(", ")}\n")
    assert_include(@ui.output, "Homepage: #{@gem.homepage}\n")
    assert_include(@ui.output, "License: #{@gem.license}\n")
    assert_include(@ui.output, "Installed at: #{@gem.base_dir}\n")
    assert_include(@ui.output, "#{@gem.summary}\n")
    assert_match "", @ui.error
  end

  def test_execute_remote_unscoped_content_addressable_gems_do_not_fetch_metadata
    spec_fetcher {}

    spec_a = util_spec "a", "1" do |s|
      s.platform = "x86_64-linux"
      s.summary = "summary a"
      s.homepage = "http://example.com"
      s.authors = ["A User"]
    end
    spec_a.content_address = "abcdef12"

    spec_b = util_spec "b", "1" do |s|
      s.platform = "arm64-darwin"
      s.summary = "summary b"
      s.homepage = "http://example.com"
      s.authors = ["B User"]
    end
    spec_b.content_address = "fedcba98"

    versions_body = +"created_at: 2026-01-01T00:00:00Z\n---\na 1-abcdef12 0000\nb 1-fedcba98 0000\n"
    versions_response = util_compact_index_response(versions_body)
    versions_response.uri = Gem::URI("#{@gem_repo}versions")
    @fetcher.data["#{@gem_repo}versions"] = versions_response
    @fetcher.data["#{@gem_repo}info/a"] = util_compact_index_response("---\n1-abcdef12 |checksum:123,ruby:~> 3.3.0,platform:= x86_64-linux\n")
    @fetcher.data["#{@gem_repo}info/b"] = util_compact_index_response("---\n1-fedcba98 |checksum:456,ruby:~> 3.4.0,platform:= arm64-darwin\n")
    path = "#{@gem_repo}quick/Marshal.#{Gem.marshal_version}/a-1-abcdef12.gemspec.rz"
    @fetcher.data[path] = Zlib::Deflate.deflate(Marshal.dump(spec_a))
    path = "#{@gem_repo}quick/Marshal.#{Gem.marshal_version}/b-1-fedcba98.gemspec.rz"
    @fetcher.data[path] = Zlib::Deflate.deflate(Marshal.dump(spec_b))
    Gem::SpecFetcher.fetcher = nil

    @cmd.handle_options %w[--remote]

    use_ui @ui do
      @cmd.execute
    end

    assert_include @ui.output, "a (1)"
    assert_include @ui.output, "b (1)"
    refute_match "Ruby ABI", @ui.output
    refute @fetcher.requests.any? {|req| req.path.start_with?("/info/") }
  end

  def test_execute_remote_content_addressable_gem_displays_real_platform_and_ruby_abi
    spec_fetcher {}

    spec = util_spec "a", "1" do |s|
      s.platform = "x86_64-linux"
      s.summary = "this is a summary"
      s.homepage = "http://example.com"
      s.authors = ["A User"]
    end
    spec.content_address = "abcdef12"

    versions_body = +"created_at: 2026-01-01T00:00:00Z\n---\na 1-abcdef12 0000\n"
    versions_response = util_compact_index_response(versions_body)
    versions_response.uri = Gem::URI("#{@gem_repo}versions")
    @fetcher.data["#{@gem_repo}versions"] = versions_response
    @fetcher.data["#{@gem_repo}info/a"] = util_compact_index_response("---\n1-abcdef12 |checksum:123,ruby:~> 3.3.0,platform:= x86_64-linux\n")

    path = "#{@gem_repo}quick/Marshal.#{Gem.marshal_version}/a-1-abcdef12.gemspec.rz"
    @fetcher.data[path] = Zlib::Deflate.deflate(Marshal.dump(spec))
    Gem::SpecFetcher.fetcher = nil

    @cmd.handle_options %w[a --remote]

    use_ui @ui do
      @cmd.execute
    end

    assert_include @ui.output, "Platforms:\n"
    assert_include @ui.output, "        x86_64-linux Ruby ABI: 3.3\n"
    refute_match "abcdef12", @ui.output
  end

  def test_execute_remote_content_addressable_gem_displays_ruby_abis_next_to_their_platforms
    spec_fetcher {}

    spec = util_spec "a", "1" do |s|
      s.platform = "x86_64-linux"
      s.summary = "this is a summary"
      s.homepage = "http://example.com"
      s.authors = ["A User"]
    end
    spec.content_address = "abcdef12"

    versions_body = +"created_at: 2026-01-01T00:00:00Z\n---\na 1-abcdef12,1-fedcba98 0000\n"
    versions_response = util_compact_index_response(versions_body)
    versions_response.uri = Gem::URI("#{@gem_repo}versions")
    @fetcher.data["#{@gem_repo}versions"] = versions_response
    @fetcher.data["#{@gem_repo}info/a"] = util_compact_index_response(<<~INFO)
      ---
      1-abcdef12 |checksum:123,ruby:~> 3.3.0,platform:= x86_64-linux
      1-fedcba98 |checksum:456,ruby:~> 3.4.0,platform:= x86_64-linux-musl
    INFO

    path = "#{@gem_repo}quick/Marshal.#{Gem.marshal_version}/a-1-abcdef12.gemspec.rz"
    @fetcher.data[path] = Zlib::Deflate.deflate(Marshal.dump(spec))
    path = "#{@gem_repo}quick/Marshal.#{Gem.marshal_version}/a-1-fedcba98.gemspec.rz"
    @fetcher.data[path] = Zlib::Deflate.deflate(Marshal.dump(spec))
    Gem::SpecFetcher.fetcher = nil

    @cmd.handle_options %w[a --remote]

    use_ui @ui do
      @cmd.execute
    end

    assert_include @ui.output, "Platforms:\n"
    assert_include @ui.output, "        x86_64-linux Ruby ABI: 3.3\n"
    assert_include @ui.output, "        x86_64-linux-musl Ruby ABI: 3.4\n"
    refute_match "Ruby ABIs: 3.3, 3.4", @ui.output
    refute_match "abcdef12", @ui.output
    refute_match "fedcba98", @ui.output
  end

  def test_execute_remote_content_addressable_and_platform_gems_display_together
    spec_fetcher {}

    spec = util_spec "a", "3" do |s|
      s.platform = "arm64-darwin"
      s.summary = "this is a summary"
      s.homepage = "http://example.com"
      s.authors = ["A User"]
    end
    spec.content_address = "fedcba98"

    versions_body = +"created_at: 2026-01-01T00:00:00Z\n---\na 1-x86_64-linux,2-abcdef12,3-fedcba98 0000\n"
    versions_response = util_compact_index_response(versions_body)
    versions_response.uri = Gem::URI("#{@gem_repo}versions")
    @fetcher.data["#{@gem_repo}versions"] = versions_response
    @fetcher.data["#{@gem_repo}info/a"] = util_compact_index_response(<<~INFO)
      ---
      2-abcdef12 |checksum:123,ruby:~> 3.3.0,platform:= x86_64-linux
      3-fedcba98 |checksum:456,ruby:~> 3.4.0,platform:= arm64-darwin
    INFO

    path = "#{@gem_repo}quick/Marshal.#{Gem.marshal_version}/a-3-fedcba98.gemspec.rz"
    @fetcher.data[path] = Zlib::Deflate.deflate(Marshal.dump(spec))
    Gem::SpecFetcher.fetcher = nil

    @cmd.handle_options %w[a --remote --all]

    use_ui @ui do
      @cmd.execute
    end

    assert_include @ui.output, "a (3, 2, 1)"
    assert_include @ui.output, "Platforms:\n"
    assert_include @ui.output, "        1: x86_64-linux\n"
    assert_include @ui.output, "        2: x86_64-linux Ruby ABI: 3.3\n"
    assert_include @ui.output, "        3: arm64-darwin Ruby ABI: 3.4\n"
    refute_match "abcdef12", @ui.output
    refute_match "fedcba98", @ui.output
  end

  def test_execute_with_version_flag
    spec_fetcher do |fetcher|
      fetcher.spec "coolgem", "1.0"
      fetcher.spec "coolgem", "2.0"
    end

    @cmd.handle_options %w[coolgem --remote --version 1.0]

    use_ui @ui do
      @cmd.execute
    end

    expected = <<~EOF

      *** REMOTE GEMS ***

      coolgem (1.0)
          Author: A User
          Homepage: http://example.com

          this is a summary
    EOF

    assert_equal expected, @ui.output
  end

  def test_execute_with_default_gem
    @gem = new_default_spec("foo", "1.0.0", nil, "default/gem.rb")

    install_default_gems @gem

    @cmd.handle_options %w[foo]

    use_ui @ui do
      @cmd.execute
    end

    assert_include(@ui.output, "#{@gem.name} (#{@gem.version})\n")
    assert_include(@ui.output, "Installed at (default): #{@gem.base_dir}\n")
    assert_match "", @ui.error
  end

  def test_execute_with_default_gem_and_regular_gem
    @default = new_default_spec("foo", "1.0.1", nil, "default/gem.rb")

    install_default_gems @default

    @regular = gem "foo", "1.0.0"

    @cmd.handle_options %w[foo]

    use_ui @ui do
      @cmd.execute
    end

    assert_include(@ui.output, "foo (1.0.1, 1.0.0)\n")
    assert_include(@ui.output, "Installed at (1.0.1, default): #{@default.base_dir}\n")
    assert_include(@ui.output, "             (1.0.0): #{@default.base_dir}\n")
    assert_match "", @ui.error
  end
end
