# frozen_string_literal: true

require_relative "helper"
require "rubygems/doctor"

class TestGemDoctor < Gem::TestCase
  def gem(name)
    spec = quick_gem name do |gem|
      gem.files = %W[lib/#{name}.rb Rakefile]
    end

    write_file File.join(*%W[gems #{spec.full_name} lib #{name}.rb])
    write_file File.join(*%W[gems #{spec.full_name} Rakefile])

    spec
  end

  def test_doctor
    a = gem "a"
    b = gem "b"
    c = gem "c"

    Gem.use_paths @userhome, @gemhome

    FileUtils.rm b.spec_file

    File.open c.spec_file, "w" do |io|
      io.write "this will raise an exception when evaluated."
    end

    assert_path_exist File.join(a.gem_dir, "Rakefile")
    assert_path_exist File.join(a.gem_dir, "lib", "a.rb")

    assert_path_exist b.gem_dir
    assert_path_not_exist b.spec_file

    assert_path_exist c.gem_dir
    assert_path_exist c.spec_file

    doctor = Gem::Doctor.new @gemhome

    capture_output do
      use_ui @ui do
        doctor.doctor
      end
    end

    assert_path_exist File.join(a.gem_dir, "Rakefile")
    assert_path_exist File.join(a.gem_dir, "lib", "a.rb")

    assert_path_not_exist b.gem_dir
    assert_path_not_exist b.spec_file

    assert_path_not_exist c.gem_dir
    assert_path_not_exist c.spec_file

    expected = <<-OUTPUT
Checking #{@gemhome}
Removed file specifications/c-2.gemspec
Removed directory gems/b-2
Removed directory gems/c-2

    OUTPUT

    assert_equal expected, @ui.output

    assert_equal Gem.dir,  @userhome
    assert_equal Gem.path, [@gemhome, @userhome]
  end

  def test_doctor_preserves_content_addressed_gems_of_other_abis
    a = gem "a"

    Gem.use_paths @userhome, @gemhome

    other_abi_spec = util_spec "b", 1 do |spec|
      spec.content_address = "aabbccdd"
      spec.required_ruby_version = "~> 9.9.0"
      spec.platform = "x86_64-linux"
    end
    other_abi_spec_dir = File.join(@gemhome, "specifications", "9.9")
    FileUtils.mkdir_p other_abi_spec_dir
    other_abi_gemspec = File.join(other_abi_spec_dir, other_abi_spec.spec_name)
    File.write other_abi_gemspec, other_abi_spec.to_ruby_for_cache

    other_abi_gem_dir = File.join(@gemhome, "gems", other_abi_spec.full_name)
    FileUtils.mkdir_p other_abi_gem_dir

    other_abi_cache_file = File.join(@gemhome, "cache", "#{other_abi_spec.full_name}.gem")
    FileUtils.mkdir_p File.dirname(other_abi_cache_file)
    File.write other_abi_cache_file, ""

    stray_gem_dir = File.join(@gemhome, "gems", "stray-9")
    FileUtils.mkdir_p stray_gem_dir

    doctor = Gem::Doctor.new @gemhome

    capture_output do
      use_ui @ui do
        doctor.doctor
      end
    end

    assert_path_exist a.spec_file
    assert_path_exist other_abi_gemspec
    assert_path_exist other_abi_gem_dir
    assert_path_exist other_abi_cache_file
    assert_path_not_exist stray_gem_dir
  end

  def test_doctor_does_not_traverse_numeric_symlinks_in_specifications_dir
    pend "symlinks not supported" if Gem.win_platform?

    a = gem "a"

    Gem.use_paths @userhome, @gemhome

    external_dir = File.join(@tempdir, "external")
    FileUtils.mkdir_p external_dir
    external_gemspec = File.join(external_dir, "victim-1.gemspec")
    File.write external_gemspec, ""

    File.symlink external_dir, File.join(@gemhome, "specifications", "9.9")

    doctor = Gem::Doctor.new @gemhome

    capture_output do
      use_ui @ui do
        doctor.doctor
      end
    end

    assert_path_exist a.spec_file
    assert_path_exist external_gemspec
  end

  def test_doctor_removes_valid_non_content_addressed_gemspec_from_abi_scoped_dir
    a = gem "a"

    Gem.use_paths @userhome, @gemhome

    non_ca_spec = util_spec "orphan", 1
    abi_spec_dir = File.join(@gemhome, "specifications", "9.9")
    FileUtils.mkdir_p abi_spec_dir
    non_ca_gemspec = File.join(abi_spec_dir, non_ca_spec.spec_name)
    File.write non_ca_gemspec, non_ca_spec.to_ruby_for_cache

    orphan_gem_dir = File.join(@gemhome, "gems", non_ca_spec.full_name)
    FileUtils.mkdir_p orphan_gem_dir

    doctor = Gem::Doctor.new @gemhome

    capture_output do
      use_ui @ui do
        doctor.doctor
      end
    end

    assert_path_exist a.spec_file
    assert_path_not_exist non_ca_gemspec
    assert_path_not_exist orphan_gem_dir
  end

  def test_doctor_removes_invalid_abi_scoped_gemspec_and_artifacts
    gem "a"

    Gem.use_paths @userhome, @gemhome

    abi_spec_dir = File.join(@gemhome, "specifications", "9.9")
    invalid_full_name = "broken-1-aabbccdd"
    invalid_gemspec = File.join(abi_spec_dir, "#{invalid_full_name}.gemspec")
    invalid_gem_dir = File.join(@gemhome, "gems", invalid_full_name)
    invalid_cache_file = File.join(@gemhome, "cache", "#{invalid_full_name}.gem")

    FileUtils.mkdir_p abi_spec_dir
    File.write invalid_gemspec, "not a gem specification"
    FileUtils.mkdir_p invalid_gem_dir
    File.write invalid_cache_file, ""

    doctor = Gem::Doctor.new @gemhome

    capture_output do
      use_ui @ui do
        doctor.doctor
      end
    end

    assert_path_exist abi_spec_dir
    assert_path_not_exist invalid_gemspec
    assert_path_not_exist invalid_gem_dir
    assert_path_not_exist invalid_cache_file
  end

  def test_doctor_preserves_abi_scoped_directories
    a = gem "a"

    Gem.use_paths @userhome, @gemhome

    spec_abi_dir = File.join(@gemhome, "specifications", Gem.ruby_abi)
    plugin_abi_dir = File.join(@gemhome, "plugins", Gem.ruby_abi)
    FileUtils.mkdir_p spec_abi_dir
    FileUtils.mkdir_p plugin_abi_dir

    doctor = Gem::Doctor.new @gemhome

    capture_output do
      use_ui @ui do
        doctor.doctor
      end
    end

    assert_path_exist a.spec_file
    assert_path_exist spec_abi_dir
    assert_path_exist plugin_abi_dir
  end

  def test_doctor_dry_run
    a = gem "a"
    b = gem "b"
    c = gem "c"

    Gem.use_paths @userhome, @gemhome

    FileUtils.rm b.spec_file

    File.open c.spec_file, "w" do |io|
      io.write "this will raise an exception when evaluated."
    end

    assert_path_exist File.join(a.gem_dir, "Rakefile")
    assert_path_exist File.join(a.gem_dir, "lib", "a.rb")

    assert_path_exist b.gem_dir
    assert_path_not_exist b.spec_file

    assert_path_exist c.gem_dir
    assert_path_exist c.spec_file

    doctor = Gem::Doctor.new @gemhome, true

    capture_output do
      use_ui @ui do
        doctor.doctor
      end
    end

    assert_path_exist File.join(a.gem_dir, "Rakefile")
    assert_path_exist File.join(a.gem_dir, "lib", "a.rb")

    assert_path_exist b.gem_dir
    assert_path_not_exist b.spec_file

    assert_path_exist c.gem_dir
    assert_path_exist c.spec_file

    expected = <<-OUTPUT
Checking #{@gemhome}
Extra file specifications/c-2.gemspec
Extra directory gems/b-2
Extra directory gems/c-2

    OUTPUT

    assert_equal expected, @ui.output

    assert_equal Gem.dir,  @userhome
    assert_equal Gem.path, [@gemhome, @userhome]
  end

  def test_doctor_non_gem_home
    other_dir = File.join @tempdir, "other", "dir"

    FileUtils.mkdir_p other_dir

    doctor = Gem::Doctor.new @tempdir

    capture_output do
      use_ui @ui do
        doctor.doctor
      end
    end

    assert_path_exist other_dir

    expected = <<-OUTPUT
Checking #{@tempdir}
This directory does not appear to be a RubyGems repository, skipping

    OUTPUT

    assert_equal expected, @ui.output
  end

  def test_doctor_child_missing
    doctor = Gem::Doctor.new @gemhome

    doctor.doctor_child "missing", ""

    assert true # count
  end

  def test_doctor_badly_named_plugins
    gem "a"

    Gem.use_paths @gemhome.to_s

    FileUtils.mkdir_p Gem.plugindir
    bad_plugin = File.join(Gem.plugindir, "a_badly_named_file.rb")
    write_file bad_plugin

    doctor = Gem::Doctor.new @gemhome

    capture_output do
      use_ui @ui do
        doctor.doctor
      end
    end

    # assert_path_not_exist bad_plugin

    expected = <<-OUTPUT
Checking #{@gemhome}
Removed file plugins/a_badly_named_file.rb

    OUTPUT

    assert_equal expected, @ui.output
  end

  def test_gem_repository_eh
    doctor = Gem::Doctor.new @gemhome

    refute doctor.gem_repository?, "no gems installed"

    install_specs util_spec "a"

    doctor = Gem::Doctor.new @gemhome

    assert doctor.gem_repository?, "gems installed"
  end
end
