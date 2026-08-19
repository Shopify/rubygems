# frozen_string_literal: true

require_relative "helper"
require "rubygems/commands/list_command"

class TestGemCommandsListCommand < Gem::TestCase
  def setup
    super

    @cmd = Gem::Commands::ListCommand.new
  end

  def test_execute_installed
    spec_fetcher do |fetcher|
      fetcher.spec "c", 1
    end

    @fetcher.data["#{@gem_repo}Marshal.#{Gem.marshal_version}"] = proc do
      raise Gem::RemoteFetcher::FetchError
    end

    @cmd.handle_options %w[c --installed]

    assert_raise Gem::MockGemUi::SystemExitException do
      use_ui @ui do
        @cmd.execute
      end
    end

    assert_equal "true\n", @ui.output
    assert_equal "", @ui.error
  end

  def test_execute_remote_unscoped_content_addressable_gems_do_not_fetch_metadata
    spec_fetcher {}

    versions_body = +"created_at: 2026-01-01T00:00:00Z\n---\na 1-abcdef12 0000\nb 1-fedcba98 0000\n"
    versions_response = util_compact_index_response(versions_body)
    versions_response.uri = Gem::URI("#{@gem_repo}versions")
    @fetcher.data["#{@gem_repo}versions"] = versions_response
    @fetcher.data["#{@gem_repo}info/a"] = util_compact_index_response("---\n1-abcdef12 |checksum:123,ruby:~> 3.3.0,platform:= x86_64-linux\n")
    @fetcher.data["#{@gem_repo}info/b"] = util_compact_index_response("---\n1-fedcba98 |checksum:456,ruby:~> 3.4.0,platform:= arm64-darwin\n")
    Gem::SpecFetcher.fetcher = nil

    @cmd.handle_options %w[--remote]

    use_ui @ui do
      @cmd.execute
    end

    assert_include @ui.output, "a (1 abcdef12)"
    assert_include @ui.output, "b (1 fedcba98)"
    refute_match "Ruby ABI", @ui.output
    refute @fetcher.requests.any? {|req| req.path.start_with?("/info/") }
  end

  def test_execute_remote_unscoped_all_content_addressable_gems_do_not_fetch_metadata
    spec_fetcher {}

    versions_body = +"created_at: 2026-01-01T00:00:00Z\n---\na 1-abcdef12,2-fedcba98 0000\n"
    versions_response = util_compact_index_response(versions_body)
    versions_response.uri = Gem::URI("#{@gem_repo}versions")
    @fetcher.data["#{@gem_repo}versions"] = versions_response
    @fetcher.data["#{@gem_repo}info/a"] = util_compact_index_response(<<~INFO)
      ---
      1-abcdef12 |checksum:123,ruby:~> 3.3.0,platform:= x86_64-linux
      2-fedcba98 |checksum:456,ruby:~> 3.4.0,platform:= arm64-darwin
    INFO
    Gem::SpecFetcher.fetcher = nil

    @cmd.handle_options %w[--remote --all]

    use_ui @ui do
      @cmd.execute
    end

    assert_include @ui.output, "a (2 fedcba98, 1 abcdef12)"
    refute_match "Ruby ABI", @ui.output
    refute @fetcher.requests.any? {|req| req.path.start_with?("/info/") }
  end

  def test_execute_remote_content_addressable_gem_displays_real_platform_and_ruby_abi
    spec_fetcher {}

    versions_body = +"created_at: 2026-01-01T00:00:00Z\n---\na 1-abcdef12 0000\nb 1-fedcba98 0000\n"
    versions_response = util_compact_index_response(versions_body)
    versions_response.uri = Gem::URI("#{@gem_repo}versions")
    @fetcher.data["#{@gem_repo}versions"] = versions_response
    @fetcher.data["#{@gem_repo}info/a"] = util_compact_index_response("---\n1-abcdef12 |checksum:123,ruby:~> 3.3.0,platform:= x86_64-linux\n")
    @fetcher.data["#{@gem_repo}info/b"] = util_compact_index_response("---\n1-fedcba98 |checksum:123,ruby:~> 3.4.0,platform:= x86_64-linux\n")
    Gem::SpecFetcher.fetcher = nil

    @cmd.handle_options %w[a --remote]

    use_ui @ui do
      @cmd.execute
    end

    assert_include @ui.output, "a (1 Platform: x86_64-linux, Ruby ABI: 3.3)"
    refute_match "abcdef12", @ui.output
    refute @fetcher.requests.any? {|req| req.path.end_with?("/info/b") }
  end

  def test_execute_remote_content_addressable_gems_displays_ruby_abis_next_to_their_platforms
    spec_fetcher {}

    versions_body = +"created_at: 2026-01-01T00:00:00Z\n---\na 1-abcdef12,1-fedcba98 0000\n"
    versions_response = util_compact_index_response(versions_body)
    versions_response.uri = Gem::URI("#{@gem_repo}versions")
    @fetcher.data["#{@gem_repo}versions"] = versions_response
    @fetcher.data["#{@gem_repo}info/a"] = util_compact_index_response(<<~INFO)
      ---
      1-abcdef12 |checksum:123,ruby:~> 3.3.0,platform:= x86_64-linux
      1-fedcba98 |checksum:456,ruby:~> 3.4.0,platform:= arm64-darwin
    INFO
    Gem::SpecFetcher.fetcher = nil

    @cmd.handle_options %w[a --remote]

    use_ui @ui do
      @cmd.execute
    end

    expected = <<~OUTPUT.chomp
      a (1 Platform: arm64-darwin, Ruby ABI: 3.4
         1 Platform: x86_64-linux, Ruby ABI: 3.3)
    OUTPUT

    assert_include @ui.output, expected
    refute_match "abcdef12", @ui.output
    refute_match "fedcba98", @ui.output
  end

  def test_execute_remote_content_addressable_gems_displays_multiple_ruby_abis_on_the_same_line
    spec_fetcher {}

    versions_body = +"created_at: 2026-01-01T00:00:00Z\n---\na 1-abcdef12,1-fedcba98 0000\n"
    versions_response = util_compact_index_response(versions_body)
    versions_response.uri = Gem::URI("#{@gem_repo}versions")
    @fetcher.data["#{@gem_repo}versions"] = versions_response
    @fetcher.data["#{@gem_repo}info/a"] = util_compact_index_response(<<~INFO)
      ---
      1-abcdef12 |checksum:123,ruby:~> 3.3.0,platform:= x86_64-linux
      1-fedcba98 |checksum:456,ruby:~> 3.4.0,platform:= x86_64-linux
    INFO
    Gem::SpecFetcher.fetcher = nil

    @cmd.handle_options %w[a --remote]

    use_ui @ui do
      @cmd.execute
    end

    assert_include @ui.output, "a (1 Platform: x86_64-linux, Ruby ABI: 3.3, 3.4)"
    refute_match "abcdef12", @ui.output
    refute_match "fedcba98", @ui.output
  end

  def test_execute_remote_content_addressable_gems_displays_multiple_versions_on_separate_lines
    spec_fetcher {}

    versions_body = +"created_at: 2026-01-01T00:00:00Z\n---\na 1-abcdef12,2-fedcba98,3-12345678 0000\n"
    versions_response = util_compact_index_response(versions_body)
    versions_response.uri = Gem::URI("#{@gem_repo}versions")
    @fetcher.data["#{@gem_repo}versions"] = versions_response
    @fetcher.data["#{@gem_repo}info/a"] = util_compact_index_response(<<~INFO)
      ---
      1-abcdef12 |checksum:123,ruby:~> 3.3.0,platform:= x86_64-linux
      2-fedcba98 |checksum:456,ruby:~> 3.4.0,platform:= x86_64-linux
      3-12345678 |checksum:789,ruby:~> 3.4.0,platform:= arm64-darwin
    INFO
    Gem::SpecFetcher.fetcher = nil

    @cmd.handle_options %w[a --remote]

    use_ui @ui do
      @cmd.execute
    end

    expected = <<~OUTPUT.chomp
      a (3 Platform: arm64-darwin, Ruby ABI: 3.4
         2 Platform: x86_64-linux, Ruby ABI: 3.4
         1 Platform: x86_64-linux, Ruby ABI: 3.3)
    OUTPUT

    assert_include @ui.output, expected
    refute_match "abcdef12", @ui.output
    refute_match "fedcba98", @ui.output
    refute_match "12345678", @ui.output
  end

  def test_execute_remote_content_addressable_and_platform_gems_display_together
    spec_fetcher {}

    versions_body = +"created_at: 2026-01-01T00:00:00Z\n---\na 1-x86_64-linux,2-abcdef12,3-fedcba98 0000\n"
    versions_response = util_compact_index_response(versions_body)
    versions_response.uri = Gem::URI("#{@gem_repo}versions")
    @fetcher.data["#{@gem_repo}versions"] = versions_response
    @fetcher.data["#{@gem_repo}info/a"] = util_compact_index_response(<<~INFO)
      ---
      2-abcdef12 |checksum:123,ruby:~> 3.3.0,platform:= x86_64-linux
      3-fedcba98 |checksum:456,ruby:~> 3.4.0,platform:= arm64-darwin
    INFO
    Gem::SpecFetcher.fetcher = nil

    @cmd.handle_options %w[a --remote --all]

    use_ui @ui do
      @cmd.execute
    end

    expected = <<~OUTPUT.chomp
      a (3 Platform: arm64-darwin, Ruby ABI: 3.4
         2 Platform: x86_64-linux, Ruby ABI: 3.3
         1 Platform: x86_64-linux)
    OUTPUT

    assert_include @ui.output, expected
    refute_match "abcdef12", @ui.output
    refute_match "fedcba98", @ui.output
  end

  def test_execute_remote_platform_gem_displays_version_once_for_multiple_platforms
    spec_fetcher {}

    versions_body = +"created_at: 2026-01-01T00:00:00Z\n---\ne 1-x86_64-linux,1-arm64-darwin 0000\n"
    versions_response = util_compact_index_response(versions_body)
    versions_response.uri = Gem::URI("#{@gem_repo}versions")
    @fetcher.data["#{@gem_repo}versions"] = versions_response
    Gem::SpecFetcher.fetcher = nil

    @cmd.handle_options %w[e --remote]

    use_ui @ui do
      @cmd.execute
    end

    assert_include @ui.output, "e (1 arm64-darwin x86_64-linux)"
  end

  def test_execute_normal_gem_shadowing_default_gem
    c1_default = new_default_spec "c", 1
    install_default_gems c1_default

    c1 = util_spec("c", 1) {|s| s.date = "2024-01-01" }
    install_gem c1

    Gem::Specification.reset

    @cmd.handle_options %w[c]

    use_ui @ui do
      @cmd.execute
    end

    expected = <<-EOF

*** LOCAL GEMS ***

c (1)
EOF

    assert_equal expected, @ui.output
  end
end
