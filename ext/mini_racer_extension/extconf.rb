require 'mkmf'

require 'fileutils'

IS_SOLARIS = RUBY_PLATFORM =~ /solaris/
IS_LINUX_MUSL = RUBY_PLATFORM =~ /linux-musl/

def cppflags_clear_std!
  $CPPFLAGS.gsub! /-std=[^\s]+/, ''
end

def cppflags_add_frame_pointer!
  $CPPFLAGS += " -fno-omit-frame-pointer"
end

def cppflags_add_cpu_extension!
  if enable_config('avx2')
    $CPPFLAGS += " -mavx2"
  else
    $CPPFLAGS += " -mssse3"
  end
end

def fixup_libtinfo
  dirs = %w[/lib64 /usr/lib64 /lib /usr/lib]
  found_v5 = dirs.map { |d| "#{d}/libtinfo.so.5" }.find &File.method(:file?)
  return '' if found_v5
  found_v6 = dirs.map { |d| "#{d}/libtinfo.so.6" }.find &File.method(:file?)
  return '' unless found_v6
  FileUtils.ln_s found_v6, 'gemdir/libtinfo.so.5', :force => true
  "LD_LIBRARY_PATH='#{File.expand_path('gemdir')}:#{ENV['LD_LIBRARY_PATH']}'"
end

def libv8_gem_name
  return "libv8-solaris" if IS_SOLARIS
  return "libv8-alpine" if IS_LINUX_MUSL

  'libv8'
end

# 1) old rubygem versions prefer source gems to binary ones
# ... and their --platform switch is broken too, as it leaves the 'ruby'
# platform in Gem.platforms.
# 2) the ruby binaries distributed with alpine (platform ending in -musl)
# refuse to load binary gems by default
def force_platform_gem
  gem_version = `gem --version`
  return 'gem' unless $?.success?

  if RUBY_PLATFORM != 'x86_64-linux-musl'
    return 'gem' if gem_version.to_f.zero? || gem_version.to_f >= 2.3
    return 'gem' if RUBY_PLATFORM != 'x86_64-linux'
  end

  gem_binary = `which gem`
  return 'gem' unless $?.success?

  ruby = File.foreach(gem_binary.strip).first.sub(/^#!/, '').strip
  unless File.file? ruby
    warn "No valid ruby: #{ruby}"
    return 'gem'
  end

  require 'tempfile'
  file = Tempfile.new('sq_mini_racer')
  file << <<EOS
require 'rubygems'
platforms = Gem.platforms
platforms.reject! { |it| it == 'ruby' }
if platforms.empty?
  platforms << Gem::Platform.new('x86_64-linux')
end
Gem.send(:define_method, :platforms) { platforms }
#{IO.read(gem_binary.strip)}
EOS
  file.close
  "#{ruby} '#{file.path}'"
end

def libv8_version
  '7.3.492.27.1'
end

def find_libv8
  libv8_path = "libv8*-#{libv8_version}-*/lib/libv8.rb"

  # find matching version in local gems
  libv8_rb = Gem.path.map { |p| p + '/gems/' + libv8_path }.map { |p| Dir.glob(p) }.flatten.first

  # find matching version in build dir
  unless libv8_rb
    libv8_glob = "**/#{libv8_path}"
    libv8_rb = Dir.glob(libv8_glob).first
  end

  # download matching version in build dir
  unless libv8_rb
    FileUtils.mkdir_p('gemdir')
    gem_name = libv8_gem_name
    cmd = "#{fixup_libtinfo} #{force_platform_gem} install --version '= #{libv8_version}' --install-dir gemdir #{gem_name}"
    puts "Will try downloading #{gem_name} gem: #{cmd}"
    `#{cmd}`
    unless $?.success?
      warn <<-WARN

      WARNING: Could not download a private copy of the libv8 gem. Please make
      sure that you have internet access and that the `gem` binary is available.

      WARN
    end

    libv8_rb = Dir.glob(libv8_glob).first
    unless libv8_rb
      warn <<-WARN

      WARNING: Could not find libv8 after the local copy of libv8 having supposedly
      been installed.

      WARN
    end
  end

  if libv8_rb
    $:.unshift(File.dirname(libv8_rb) + '/../ext')
    $:.unshift File.dirname(libv8_rb)
  end
end

find_libv8

require 'libv8'

IS_DARWIN = RUBY_PLATFORM =~ /darwin/

have_library('pthread')
have_library('objc') if IS_DARWIN
cppflags_clear_std!
$CPPFLAGS += " -Wall" unless $CPPFLAGS.split.include? "-Wall"
$CPPFLAGS += " -g" unless $CPPFLAGS.split.include? "-g"
$CPPFLAGS += " -rdynamic" unless $CPPFLAGS.split.include? "-rdynamic"
$CPPFLAGS += " -fPIC" unless $CPPFLAGS.split.include? "-rdynamic" or IS_DARWIN
$CPPFLAGS += " -std=c++0x"
$CPPFLAGS += " -fpermissive"
cppflags_add_frame_pointer!
cppflags_add_cpu_extension!

$CPPFLAGS += " -Wno-reserved-user-defined-literal" if IS_DARWIN

$LDFLAGS.insert(0, " -stdlib=libc++ ") if IS_DARWIN

if ENV['CXX']
  puts "SETTING CXX"
  CONFIG['CXX'] = ENV['CXX']
end

CXX11_TEST = <<EOS
#if __cplusplus <= 199711L
#   error A compiler that supports at least C++11 is required in order to compile this project.
#endif
EOS

`echo "#{CXX11_TEST}" | #{CONFIG['CXX']} -std=c++0x -x c++ -E -`
unless $?.success?
  warn <<EOS


WARNING: C++11 support is required for compiling mini_racer. Please make sure
you are using a compiler that supports at least C++11. Examples of such
compilers are GCC 4.7+ and Clang 3.2+.

If you are using Travis, consider either migrating your build to Ubuntu Trusty or
installing GCC 4.8. See mini_racer's README.md for more information.


EOS
end

CONFIG['LDSHARED'] = '$(CXX) -shared' unless IS_DARWIN
if CONFIG['warnflags']
  CONFIG['warnflags'].gsub!('-Wdeclaration-after-statement', '')
  CONFIG['warnflags'].gsub!('-Wimplicit-function-declaration', '')
end

if enable_config('debug') || enable_config('asan')
  CONFIG['debugflags'] << ' -ggdb3 -O0'
end

Libv8.configure_makefile

if enable_config('asan')
  $CPPFLAGS.insert(0, " -fsanitize=address ")
  $LDFLAGS.insert(0, " -fsanitize=address ")
end

create_makefile 'sq_mini_racer_extension'
