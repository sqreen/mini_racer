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
  #return "libv8-solaris" if IS_SOLARIS
  #return "libv8-alpine" if IS_LINUX_MUSL

  'libv8-node'
end

def libv8_requirement
  '~> 10.22.1.0.beta1'
end

def libv8_basename(version)
  "#{libv8_gem_name}-#{version}-#{ruby_platform}"
end

def libv8_gemspec(version)
  "#{libv8_basename(version)}.gemspec"
end

def libv8_local_path(path=Gem.path)
  name_glob = "#{libv8_gem_name}-*-#{ruby_platform}"

  puts "looking for #{name_glob} in #{path.inspect}"

  paths = path.map { |p| Dir.glob(File.join(p, 'specifications', name_glob + '.gemspec')) }.flatten

  if paths.empty?
    puts "#{name_glob} not found in #{path.inspect}"
    return
  end

  specs = paths.map { |p| [p, eval(File.read(p))] }
               .select { |_, spec| Gem::Requirement.new(libv8_requirement).satisfied_by?(spec.version) }
  found_path, found_spec = specs.sort_by { |_, spec| spec.version }.last

  unless found_path && found_spec
    puts "not found in specs: no '#{libv8_requirement}' in #{paths.inspect}"
    return
  end

  puts "found in specs: #{found_path}"

  gemdir = File.basename(found_path, '.gemspec')
  dir = File.expand_path(File.join(found_path, '..', '..', 'gems', gemdir))

  unless Dir.exist?(dir)
    puts "not found in gems: #{dir}"
    return
  end

  puts "found in gems: #{dir}"

  [dir, found_spec]
end

def vendor_path
  File.join(Dir.pwd, 'vendor')
end

def libv8_vendor_path
  libv8_local_path([vendor_path])
end

def parse_platform(str)
  Gem::Platform.new(str).tap do |p|
    p.instance_eval { @version = 'musl' } if str =~ /-musl/ && p.version.nil?
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
    Gem::Requirement.new(libv8_requirement).satisfied_by?(Gem::Version.new(v['number']))
  end
  abort(<<-ERROR) if versions.empty?
  ERROR: could not find #{libv8_gem_name} (requirement #{libv8_requirement}) in rubygems.org
  ERROR

  platform_versions = versions.select do |v|
    parse_platform(v['platform']) == ruby_platform unless v['platform'] =~ /universal.*darwin/
  end
  abort(<<-ERROR) if platform_versions.empty?
  ERROR: found gems matching #{libv8_gem_name}:'#{libv8_requirement}', but no binary for #{ruby_platform}
         try "gem install #{libv8_gem_name}:'#{libv8_requirement}'" to attempt to build #{libv8_gem_name} from source
  ERROR

  puts "found #{libv8_gem_name} for #{ruby_platform} on rubygems: #{platform_versions.map { |v| v['number'] }.join(', ')}"

  platform_versions.sort_by { |v| Gem::Version.new(v['number']) }.last
end

def libv8_download_uri(name, version, platform)
  URI("https://rubygems.org/downloads/#{name}-#{version}-#{platform}.gem")
end

def libv8_downloaded_gem(name, version, platform)
  "#{name}-#{version}-#{platform}.gem"
end

def libv8_download(name, version, platform)
  FileUtils.mkdir_p(File.join(vendor_path, 'cache'))
  body = http_get(libv8_download_uri(name, version, platform))
  File.open(File.join(vendor_path, 'cache', libv8_downloaded_gem(name, version, platform)), 'wb') { |f| f.write(body) }
end

def libv8_install!
  cmd = "gem install #{libv8_gem_name} --version '#{libv8_requirement}' --install-dir '#{vendor_path}'"
  puts "installing #{libv8_gem_name} using `#{cmd}`"
  rc = system(cmd)

  abort(<<-ERROR) unless rc
  ERROR: could not install #{libv8_gem_name}:#{libv8_requirement}
          try "gem install #{libv8_gem_name} -v '#{libv8_requirement}'" to attempt to build libv8 from source
  ERROR

  libv8_local_path([vendor_path])
end

def libv8_vendor!
  return libv8_install! if Gem::VERSION < '2.0'

  version = libv8_remote_search

  puts "downloading #{libv8_downloaded_gem(libv8_gem_name, version['number'], version['platform'])} to #{vendor_path}"
  libv8_download(libv8_gem_name, version['number'], version['platform'])

  package = Gem::Package.new(File.join(vendor_path, 'cache', libv8_downloaded_gem(libv8_gem_name, version['number'], version['platform'])))
  package.extract_files(File.join(vendor_path, 'gems', File.basename(libv8_downloaded_gem(libv8_gem_name, version['number'], version['platform']), '.gem')))
  FileUtils.mkdir_p(File.join(vendor_path, 'specifications'))
  File.open(File.join(vendor_path, 'specifications', File.basename(libv8_downloaded_gem(libv8_gem_name, version['number'], version['platform']), '.gem') + '.gemspec'), 'wb') { |f| f.write(package.spec.to_ruby) }

  libv8_vendor_path
end

def ensure_libv8_load_path
  puts "platform ruby:#{RUBY_PLATFORM} rubygems:#{Gem::Platform.new(RUBY_PLATFORM)} detected:#{ruby_platform}"

  libv8_path, spec = libv8_local_path
  if !ENV['ONLY_INSTALLED_LIBV8_GEM'] && !libv8_path
    libv8_path, spec = libv8_vendor_path || libv8_vendor!
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
cppflags_add_frame_pointer!
cppflags_add_cpu_extension!

$CPPFLAGS += " -Wno-reserved-user-defined-literal" if IS_DARWIN

$LDFLAGS.insert(0, " -stdlib=libc++ ") if IS_DARWIN
$LDFLAGS += " -Wl,--no-undefined " unless IS_DARWIN
$LDFLAGS += " -Wl,-undefined,error " if IS_DARWIN

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

Libv8::Node.configure_makefile

if enable_config('asan')
  $CPPFLAGS.insert(0, " -fsanitize=address ")
  $LDFLAGS.insert(0, " -fsanitize=address ")
end

create_makefile 'sq_mini_racer_extension'
