require 'mkmf'

IS_DARWIN = RUBY_PLATFORM =~ /darwin/

have_library('pthread')
have_library('objc') if IS_DARWIN
$CPPFLAGS += " -Wall" unless $CPPFLAGS.split.include? "-Wall"
$CPPFLAGS += " -g" unless $CPPFLAGS.split.include? "-g"
$CPPFLAGS += " -rdynamic" unless $CPPFLAGS.split.include? "-rdynamic"
$CPPFLAGS += " -fPIC" unless $CPPFLAGS.split.include? "-rdynamic" or IS_DARWIN
$CPPFLAGS += " -std=c++0x"
$CPPFLAGS += " -fpermissive"

$CPPFLAGS += " -Wno-reserved-user-defined-literal" if IS_DARWIN

MAC_OS_VERSION = begin
  if IS_DARWIN
    # note, RUBY_PLATFORM is hardcoded on compile, it can not be trusted
    # sw_vers can be trusted so use it
    `sw_vers -productVersion`.to_f rescue 0.0
  else
    0.0
  end
end

$LDFLAGS.insert 0, MAC_OS_VERSION < 10.14 ? " -stdlib=libstdc++ " : " -stdlib=libc++ " if IS_DARWIN

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

if enable_config('debug')
  CONFIG['debugflags'] << ' -ggdb3 -O0'
end

def fixup_libtinfo
  dirs = %w[/lib64 /usr/lib64 /lib /usr/lib]
  found_v5 = dirs.map { |d| "#{d}/libtinfo.so.5" }.find &File.method(:file?)
  return '' if found_v5
  found_v6 = dirs.map { |d| "#{d}/libtinfo.so.6" }.find &File.method(:file?)
  return '' unless found_v6
  FileUtils.ln_s found_v6, 'gemdir/libtinfo.so.5', :force => true
  "LD_LIBRARY_PATH='#{File.expand_path('gemdir')}:#{ENV['LD_LIBRARY_PATH']}"
end

def libv8_gem_name
  is_musl = false
  begin
    is_musl = !!(File.read('/proc/self/maps') =~ /ld-musl-x86_64/)
  rescue; end

  is_musl ? 'libv8-alpine' : 'libv8'
end

LIBV8_VERSION = '6.7.288.46.1'
libv8_rb = Dir.glob('**/libv8.rb').first
FileUtils.mkdir_p('gemdir')
unless libv8_rb
  gem_name = libv8_gem_name
  puts "Will try downloading #{gem_name} gem, version #{LIBV8_VERSION}"
  `#{fixup_libtinfo} gem install --version '= #{LIBV8_VERSION}' --install-dir gemdir #{gem_name}`
  unless $?.success?
    warn <<EOS

WARNING: Could not download a private copy of the libv8 gem. Please make
sure that you have internet access and that the `gem` binary is available.

EOS
  end

  libv8_rb = Dir.glob('**/libv8.rb').first
  unless libv8_rb
    warn <<EOS

WARNING: Could not find libv8 after the local copy of libv8 having supposedly
been installed.

EOS
  end
end

if libv8_rb
  $:.unshift(File.dirname(libv8_rb) + '/../ext')
  $:.unshift File.dirname(libv8_rb)
end

require 'libv8'
Libv8.configure_makefile
create_makefile 'sq_mini_racer_extension'
