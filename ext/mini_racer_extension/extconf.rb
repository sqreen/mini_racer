require 'mkmf'

require 'fileutils'
require 'net/http'
require 'json'
require 'rubygems'
require 'rubygems/package'

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

def libv8_gem_name
  'libv8-node'
end

def libv8_version
  '14.14.0.0.beta2'
end

def libv8_basename
  "#{libv8_gem_name}-#{libv8_version}-#{ruby_platform}"
end

def libv8_gemspec_no_libc
  platform_no_libc = ruby_platform.to_s.split('-')[0..1].join('-')
  "#{libv8_gem_name}-#{libv8_version}-#{platform_no_libc}.gemspec"
end

def libv8_gemspec
  "#{libv8_basename}.gemspec"
end

def libv8_local_path(path=Gem.path)
  gemspecs = [libv8_gemspec, libv8_gemspec_no_libc].uniq
  puts "looking for #{gemspecs.join(', ')} in installed gems"
  candidates = path.product(gemspecs)
    .map { |(p, gemspec)| File.join(p, 'specifications', gemspec) }
  p candidates
  found = candidates.select { |f| File.exist?(f) }.first

  unless found
    puts "#{gemspecs.join(', ')} not found in installed gems"
    return
  end

  puts "found in installed specs: #{found}"

  gemdir = File.basename(found, '.gemspec')
  dir = File.expand_path(File.join(found, '..', '..', 'gems', gemdir))

  unless Dir.exist?(dir)
    puts "not found in installed gems: #{dir}"
    return
  end

  puts "found in installed gems: #{dir}"

  dir
end

def vendor_path
  File.join(Dir.pwd, 'vendor')
end

def libv8_vendor_path
  puts "looking for #{libv8_basename} in #{vendor_path}"
  path = Dir.glob("#{vendor_path}/#{libv8_basename}").first

  unless path
    puts "#{libv8_basename} not found in #{vendor_path}"
    return
  end

  puts "looking for #{libv8_basename}/lib/libv8-node.rb in #{vendor_path}"
  unless Dir.glob(File.join(vendor_path, libv8_basename, 'lib', 'libv8-node.rb')).first
    puts "#{libv8_basename}/lib/libv8.rb not found in #{vendor_path}"
    return
  end

  path
end

def parse_platform(str)
  Gem::Platform.new(str).tap do |p|
    p.instance_eval { @cpu = 'x86_64' } if str =~ /universal.*darwin/
  end
end

def ruby_platform
  parse_platform(RUBY_PLATFORM)
end

def http_get(uri)
  Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
    res = http.get(uri.path)

    abort("HTTP error #{res.code}: #{uri}") unless res.code == '200'

    return res.body
  end
end

def libv8_remote_search
  body = http_get(URI("https://rubygems.org/api/v1/versions/#{libv8_gem_name}.json"))
  json = JSON.parse(body)

  versions = json.select do |v|
    Gem::Version.new(v['number']) == Gem::Version.new(libv8_version)
  end
  abort(<<-ERROR) if versions.empty?
  ERROR: could not find #{libv8_gem_name} (version #{libv8_version}) in rubygems.org
  ERROR

  platform_versions = versions.select do |v|
    parse_platform(v['platform']) == ruby_platform unless v['platform'] =~ /universal.*darwin/
  end
  abort(<<-ERROR) if platform_versions.empty?
  ERROR: found #{libv8_gem_name}-#{libv8_version}, but no binary for #{ruby_platform}
         try "gem install #{libv8_gem_name} -v '#{libv8_version}'" to attempt to build libv8 from source
  ERROR

  platform_versions.first
end

def libv8_download_uri(name, version, platform)
  URI("https://rubygems.org/downloads/#{name}-#{version}-#{platform}.gem")
end

def libv8_downloaded_gem(name, version, platform)
  "#{name}-#{version}-#{platform}.gem"
end

def libv8_download(name, version, platform)
  FileUtils.mkdir_p(vendor_path)
  body = http_get(libv8_download_uri(name, version, platform))
  File.open(File.join(vendor_path, libv8_downloaded_gem(name, version, platform)), 'wb') { |f| f.write(body) }
end

def libv8_install!
  cmd = "gem install #{libv8_gem_name} --version '#{libv8_version}' --install-dir '#{vendor_path}'"
  puts "installing #{libv8_gem_name} using `#{cmd}`"
  rc = system(cmd)

  abort(<<-ERROR) unless rc
  ERROR: could not install #{libv8_gem_name} #{libv8_version}
          try "gem install #{libv8_gem_name} -v '#{libv8_version}'" to attempt to build libv8 from source
  ERROR

  libv8_local_path([vendor_path])
end

def libv8_vendor!
  return libv8_install! if Gem::VERSION < '2.0'

  version = libv8_remote_search

  puts "downloading #{libv8_downloaded_gem(libv8_gem_name, version['number'], version['platform'])} to #{vendor_path}"
  libv8_download(libv8_gem_name, version['number'], version['platform'])

  package = Gem::Package.new(File.join(vendor_path, libv8_downloaded_gem(libv8_gem_name, version['number'], version['platform'])))
  package.extract_files(File.join(vendor_path, File.basename(libv8_downloaded_gem(libv8_gem_name, version['number'], version['platform']), '.gem')))

  libv8_vendor_path
end

def ensure_libv8_load_path
  puts "detected platform #{RUBY_PLATFORM} => #{ruby_platform}"

  libv8_path = libv8_local_path
  unless ENV['ONLY_INSTALLED_LIBV8_GEM']
    libv8_path ||= libv8_vendor_path || libv8_vendor!
  end

  abort(<<-ERROR) unless libv8_path
  ERROR: could not find #{libv8_gem_name}
  ERROR

  $LOAD_PATH.unshift(File.join(libv8_path, 'ext'))
  $LOAD_PATH.unshift(File.join(libv8_path, 'lib'))
end

ensure_libv8_load_path

require 'libv8-node'

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
$CPPFLAGS += " -DV8_COMPRESS_POINTERS"
$CPPFLAGS += " -fvisibility=hidden "
cppflags_add_frame_pointer!
cppflags_add_cpu_extension!

$CPPFLAGS += " -Wno-reserved-user-defined-literal" if IS_DARWIN

$LDFLAGS.insert(0, " -stdlib=libc++ ") if IS_DARWIN
$LDFLAGS += " -Wl,--no-undefined " unless IS_DARWIN

if ENV['CXX']
  puts "SETTING CXX"
  CONFIG['CXX'] = ENV['CXX']
end
# 1.9 has no $CXXFLAGS
$CPPFLAGS += " #{ENV['CPPFLAGS']}" if ENV['CPPFLAGS']
$LDFLAGS  += " #{ENV['LDFLAGS']}" if ENV['LDFLAGS']

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

Libv8::Node.configure_makefile

if enable_config('asan')
  $CPPFLAGS.insert(0, " -fsanitize=address ")
  $LDFLAGS.insert(0, " -fsanitize=address ")
end

create_makefile 'sq_mini_racer_extension'
