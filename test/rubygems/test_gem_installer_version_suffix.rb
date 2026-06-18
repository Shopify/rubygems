# frozen_string_literal: true

require_relative "helper"
require "rubygems/installer"
require "rubygems/package"
require "digest"
require "fileutils"

##
# Exercises how Gem::Installer assigns the content-addressable version suffix:
# it trusts the width carried by the gem's file name (the registry/build token)
# and only derives/grows a width locally for a bare local install whose file
# name carries no token.

class TestGemInstallerVersionSuffix < Gem::TestCase
  def setup
    super

    abi = RUBY_VERSION.split(".").first(2).join(".")
    @spec = Gem::Specification.new do |s|
      s.name                 = "skinny"
      s.version              = "1.0.0"
      s.summary              = "skinny binary fixture"
      s.authors              = ["Test"]
      s.platform             = Gem::Platform.new("x86_64-linux")
      s.required_ruby_version = "~> #{abi}.0"
      s.files                = []
    end

    assert @spec.content_addressable?, "fixture must be content-addressable"
  end

  def build_gem
    Dir.chdir @tempdir do
      File.join(@tempdir, Gem::Package.build(@spec))
    end
  end

  def install(path)
    installer = Gem::Installer.at(path, force: true)
    installer.install
    installer
  end

  def gem_dir(suffix)
    File.join @gemhome, "gems", "skinny-1.0.0-#{suffix}"
  end

  def test_default_width_taken_from_built_file_name
    gem  = build_gem
    full = Digest::SHA256.file(gem).hexdigest

    installer = install(gem)

    assert_equal full[0, 8], installer.spec.version_suffix
    assert_path_exist gem_dir(full[0, 8])
  end

  def test_trusts_wider_registry_token_verbatim
    gem  = build_gem
    full = Digest::SHA256.file(gem).hexdigest

    # Registry published a wider token (collision resolved upstream); the
    # download arrives as name-version-<sha10>.gem. The client must use that
    # width as-is rather than recomputing the default width.
    wider = File.join(@tempdir, "skinny-1.0.0-#{full[0, 10]}.gem")
    FileUtils.mv gem, wider

    installer = install(wider)

    assert_equal full[0, 10], installer.spec.version_suffix
    assert_path_exist gem_dir(full[0, 10])
  end

  def test_ignores_filename_token_that_is_not_a_real_prefix
    gem  = build_gem
    full = Digest::SHA256.file(gem).hexdigest

    # A token that looks valid but is not a prefix of the real digest must be
    # rejected, falling back to a locally-derived width.
    bogus = full[0, 8].tr("0123456789abcdef", "fedcba9876543210")
    refute full.start_with?(bogus)
    renamed = File.join(@tempdir, "skinny-1.0.0-#{bogus}.gem")
    FileUtils.mv gem, renamed

    installer = install(renamed)

    assert_equal full[0, 8], installer.spec.version_suffix
  end

  def test_grows_width_on_local_collision
    gem  = build_gem
    full = Digest::SHA256.file(gem).hexdigest

    # Bare local install: strip the token so the installer derives one locally.
    plain = File.join(@tempdir, "skinny-1.0.0.gem")
    FileUtils.cp gem, plain

    # A *different* gem already occupies the default-width prefix.
    FileUtils.mkdir_p gem_dir(full[0, 8])
    FileUtils.mkdir_p File.join(@gemhome, "cache")
    File.binwrite File.join(@gemhome, "cache", "skinny-1.0.0-#{full[0, 8]}.gem"),
                  "a-different-gem"

    installer = install(plain)

    assert_equal full[0, 10], installer.spec.version_suffix
    assert_path_exist gem_dir(full[0, 10])
  end

  def test_reuses_existing_wider_width_for_identical_content
    gem  = build_gem
    full = Digest::SHA256.file(gem).hexdigest

    plain = File.join(@tempdir, "skinny-1.0.0.gem")
    FileUtils.cp gem, plain

    # The same content is already installed under a *wider* width (e.g. the
    # registry grew it). A local install of identical bytes must reuse that
    # directory, not create a second copy at the default width.
    FileUtils.mkdir_p gem_dir(full[0, 10])
    FileUtils.mkdir_p File.join(@gemhome, "cache")
    FileUtils.cp gem, File.join(@gemhome, "cache", "skinny-1.0.0-#{full[0, 10]}.gem")

    installer = install(plain)

    assert_equal full[0, 10], installer.spec.version_suffix
    assert_path_not_exist gem_dir(full[0, 8])
  end

  def test_reuses_width_on_idempotent_local_reinstall
    gem  = build_gem
    full = Digest::SHA256.file(gem).hexdigest

    plain = File.join(@tempdir, "skinny-1.0.0.gem")
    FileUtils.cp gem, plain

    # The *same* content is already cached at the default width: keep that width.
    FileUtils.mkdir_p gem_dir(full[0, 8])
    FileUtils.mkdir_p File.join(@gemhome, "cache")
    FileUtils.cp gem, File.join(@gemhome, "cache", "skinny-1.0.0-#{full[0, 8]}.gem")

    installer = install(plain)

    assert_equal full[0, 8], installer.spec.version_suffix
  end

  def test_installing_wider_registry_gem_prunes_stale_narrower_duplicate
    gem  = build_gem
    full = Digest::SHA256.file(gem).hexdigest

    # A stale default-width (local) install of identical content is on disk.
    FileUtils.mkdir_p gem_dir(full[0, 8])
    FileUtils.mkdir_p File.join(@gemhome, "cache")
    FileUtils.cp gem, File.join(@gemhome, "cache", "skinny-1.0.0-#{full[0, 8]}.gem")

    # Now install the registry's wider (canonical) copy of the same bytes.
    wider = File.join(@tempdir, "skinny-1.0.0-#{full[0, 10]}.gem")
    FileUtils.cp gem, wider

    installer = install(wider)

    # The wider address wins, and the narrower duplicate is removed: exactly
    # one directory remains, so activation is never a tie.
    assert_equal full[0, 10], installer.spec.version_suffix
    assert_path_exist gem_dir(full[0, 10])
    assert_path_not_exist gem_dir(full[0, 8])
  end

  def test_installing_narrower_local_gem_adopts_existing_wider_remote
    gem  = build_gem
    full = Digest::SHA256.file(gem).hexdigest

    # The wider (registry) copy is already installed.
    FileUtils.mkdir_p gem_dir(full[0, 10])
    FileUtils.mkdir_p File.join(@gemhome, "cache")
    FileUtils.cp gem, File.join(@gemhome, "cache", "skinny-1.0.0-#{full[0, 10]}.gem")

    # Installing a narrower local build of identical bytes must defer to the
    # wider remote address rather than create a second directory.
    installer = install(gem) # built file name carries the default width 8

    assert_equal full[0, 10], installer.spec.version_suffix
    assert_path_exist gem_dir(full[0, 10])
    assert_path_not_exist gem_dir(full[0, 8])
  end
end
