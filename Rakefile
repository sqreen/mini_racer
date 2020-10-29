require "bundler/gem_tasks"
require "rake/testtask"
require "rake/extensiontask"
require "shellwords"

class ValgrindTestTask < Rake::TestTask
  VALGRIND_EXEC = 'valgrind'
  DEFAULT_VALGRIND_OPTS = %w{
    --trace-children=yes
    --partial-loads-ok=yes
    --error-limit=no
    --error-exitcode=33
    --num-callers=100
    --suppressions=valgrind.supp
    --gen-suppressions=all
  }

  attr_accessor :valgrind_args

  def initialize(name=:valgrind_test)
    @valgrind_args = DEFAULT_VALGRIND_OPTS
    super
  end

  # see original def in fileutils.rb
  def ruby(*args, &block)
    options = (Hash === args.last) ? args.pop : {}
    if args.length > 1
      sh(*([VALGRIND_EXEC] + valgrind_args + [RUBY] + args + [options]), &block)
    else
      # if the size is 1 it's assumed the arguments are already escaped
      non_escaped_args = [VALGRIND_EXEC] + valgrind_args + [RUBY]
      sh("#{non_escaped_args.map { |s| Shellwords.escape(s) }.join(' ')} #{args.first}", options, &block)
  end
  end
end

test_task_cfg = Proc.new do |t|
  t.libs << 'test'
  t.libs << 'lib'
  t.test_files = FileList['test/**/*_test.rb']
  end

Rake::TestTask.new(:test, &test_task_cfg)
ValgrindTestTask.new(:'test:valgrind', &test_task_cfg)

task :default => [:compile, :test]

gem = Gem::Specification.load( File.dirname(__FILE__) + '/mini_racer.gemspec' )
Rake::ExtensionTask.new( 'mini_racer_loader', gem ) do |ext|
  ext.name = 'sq_mini_racer_loader'
end
Rake::ExtensionTask.new( 'mini_racer_extension', gem ) do |ext|
  ext.name = 'sq_mini_racer_extension'
end

desc 'run clang-tidy linter on mini_racer_extension.cc'
task :lint do
  require 'mkmf'
  require 'libv8'

  Libv8.configure_makefile

  conf = RbConfig::CONFIG.merge('hdrdir' => $hdrdir.quote, 'srcdir' => $srcdir.quote,
                                'arch_hdrdir' => $arch_hdrdir.quote,
                                'top_srcdir' => $top_srcdir.quote)
  if $universal and (arch_flag = conf['ARCH_FLAG']) and !arch_flag.empty?
    conf['ARCH_FLAG'] = arch_flag.gsub(/(?:\G|\s)-arch\s+\S+/, '')
  end

  checks = %W(bugprone-*
              cert-*
              cppcoreguidelines-*
              clang-analyzer-*
              performance-*
              portability-*
              readability-*).join(',')

  sh RbConfig::expand("clang-tidy -checks='#{checks}' ext/mini_racer_extension/mini_racer_extension.cc -- #$INCFLAGS #$CPPFLAGS", conf)
end
