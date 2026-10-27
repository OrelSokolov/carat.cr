# carat — глобальный установщик бинарников для Crystal-шардов.
#
# `carat install owner/repo` тащит шард с GitHub, собирает `binaries:`
# через `crystal build --release` и кладёт самодостаточные бинарники в ~/.carat/bin.
#
# Архитектура: порты и адаптеры (по образцу Egui::SystemPorts) — ядро не знает
# про ОС, платформенные различия живут в адаптерах, выбор — compile-time флаги.

require "yaml"
require "file_utils"
require "colorize"

module Carat
  VERSION = "0.4.0"

  class Error < Exception
  end

  # ------------------------------------------------------------------
  # Порты
  # ------------------------------------------------------------------

  module Ports
    abstract class Environment
      abstract def home : String
      abstract def path_separator : String
    end

    class PosixEnvironment < Environment
      def home : String
        ENV["HOME"]? || raise Error.new("HOME is not set")
      end

      def path_separator : String
        ":"
      end
    end

    class WindowsEnvironment < Environment
      def home : String
        if profile = ENV["USERPROFILE"]?
          profile
        elsif (drive = ENV["HOMEDRIVE"]?) && (path = ENV["HOMEPATH"]?)
          File.join(drive, path)
        else
          raise Error.new("cannot determine home directory (USERPROFILE / HOMEDRIVE+HOMEPATH)")
        end
      end

      def path_separator : String
        ";"
      end
    end

    abstract class Shell
      abstract def run(command : String, args : Array(String), cwd : String?) : Bool
      abstract def run_command(command : String, cwd : String?) : Bool
      abstract def which(command : String) : String?
    end

    class SystemShell < Shell
      def run(command : String, args : Array(String), cwd : String?) : Bool
        Process.run(command, args,
          chdir: cwd,
          output: Process::Redirect::Inherit,
          error: Process::Redirect::Inherit).success?
      end

      # A shell command line (prebuild: in binaries:) — run through the
      # platform shell so pipes/globs/env assignments work.
      def run_command(command : String, cwd : String?) : Bool
        {% if flag?(:windows) %}
          Process.run("cmd", ["/c", command], chdir: cwd,
            output: Process::Redirect::Inherit,
            error: Process::Redirect::Inherit).success?
        {% else %}
          Process.run("sh", ["-c", command], chdir: cwd,
            output: Process::Redirect::Inherit,
            error: Process::Redirect::Inherit).success?
        {% end %}
      end

      def which(command : String) : String?
        return command if command.includes?(File::SEPARATOR) && Carat.executable_file?(command)
        path = ENV["PATH"]?
        return nil unless path
        path.split(Carat.env.path_separator).each do |dir|
          next if dir.empty?
          candidate = File.join(dir, command)
          return candidate if Carat.executable_file?(candidate)
        end
        nil
      end
    end

    abstract class Logger
      abstract def log(line : String) : Nil
    end

    class FileLogger < Logger
      def initialize(@path : String)
      end

      def log(line : String) : Nil
        Dir.mkdir_p(File.dirname(@path))
        File.open(@path, "a") do |f|
          f.puts "#{Time.local.to_s("%Y-%m-%dT%H:%M:%S%z")} #{line}"
        end
      end
    end
  end

  @@env : Ports::Environment? = nil
  @@shell : Ports::Shell? = nil
  @@logger : Ports::Logger? = nil

  def self.executable_file?(path : String) : Bool
    # любой execute-бит (0o111)
    !!File.info?(path).try { |info| (info.permissions.value & 0o111) != 0 }
  end

  # Цвета только для интерактивного вывода: NO_COLOR и редирект в пайп
  # отключают escape-коды (иначе они засоряют логи и вывод в файлах).
  def self.colors? : Bool
    !ENV["NO_COLOR"]? && STDOUT.tty? && STDERR.tty?
  end

  def self.paint(line : String, color : Colorize::Color) : String
    colors? ? line.colorize(color).to_s : line
  end

  def self.warning(line : String) : Nil
    puts paint(line, :yellow)
  end

  def self.env : Ports::Environment
    @@env ||= {% if flag?(:windows) %}Ports::WindowsEnvironment.new{% else %}Ports::PosixEnvironment.new{% end %}
  end

  def self.shell : Ports::Shell
    @@shell ||= Ports::SystemShell.new
  end

  def self.logger : Ports::Logger
    @@logger ||= Ports::FileLogger.new(Paths.log_file)
  end

  # ------------------------------------------------------------------
  # Ядро: пути
  # ------------------------------------------------------------------

  module Paths
    def self.carat_home : String
      File.join(Carat.env.home, ".carat")
    end

    def self.bin_dir : String
      File.join(carat_home, "bin")
    end

    # Куда кладёт бинарники --system: /usr/local/bin на Unix (каталог для
    # вручную установленного софта, на PATH по умолчанию; /bin на macOS
    # read-only из-за SIP, на Linux — территория пакетного менеджера) и
    # %ProgramFiles%\carat\bin на Windows.
    def self.system_bin_dir : String
      {% if flag?(:windows) %}
        program_files = ENV["ProgramFiles"]? || ENV["ProgramW6432"]? || "C:\\Program Files"
        File.join(program_files, "carat", "bin")
      {% else %}
        "/usr/local/bin"
      {% end %}
    end

    def self.examples_dir : String
      File.join(carat_home, "examples")
    end

    def self.shards_dir : String
      File.join(carat_home, "shards")
    end

    def self.shard_dir(name : String, version : String) : String
      File.join(shards_dir, name, version)
    end

    def self.current_pointer(name : String) : String
      File.join(shards_dir, name, "current")
    end

    def self.logs_dir : String
      File.join(carat_home, "logs")
    end

    def self.log_file : String
      File.join(logs_dir, "carat.log")
    end

    def self.tmp_dir : String
      File.join(carat_home, "tmp")
    end

    def self.project_bin : String
      File.join(Dir.current, ".carat", "bin")
    end

    def self.project_examples : String
      File.join(Dir.current, ".carat", "examples")
    end

    def self.ensure_global_dirs : Nil
      [bin_dir, shards_dir, logs_dir, tmp_dir].each { |d| Dir.mkdir_p(d) }
    end
  end

  # ------------------------------------------------------------------
  # Ядро: semver
  # ------------------------------------------------------------------

  class SemVer
    include Comparable(SemVer)

    getter major : Int32
    getter minor : Int32
    getter patch : Int32
    getter pre : String?

    def initialize(@major : Int32, @minor : Int32, @patch : Int32, @pre : String? = nil)
    end

    def self.parse(raw : String) : self
      s = raw.strip
      s = s[1..] if s.starts_with?('v')
      pre = nil
      if idx = s.index('-')
        pre = s[(idx + 1)..]
        s = s[0...idx]
      end
      parts = s.split('.').map { |p| p.to_i? || 0 }
      new(parts[0]? || 0, parts[1]? || 0, parts[2]? || 0, pre)
    end

    def <=>(other : SemVer) : Int32
      cmp = major <=> other.major
      return cmp unless cmp == 0
      cmp = minor <=> other.minor
      return cmp unless cmp == 0
      cmp = patch <=> other.patch
      return cmp unless cmp == 0
      a, b = pre, other.pre
      return 0 if a.nil? && b.nil?
      return 1 if a.nil? # релиз выше пререлиза
      return -1 if b.nil?
      a <=> b
    end

    def to_s(io : IO) : Nil
      io << major << '.' << minor << '.' << patch
      io << '-' << pre if pre
    end
  end

  # ------------------------------------------------------------------
  # Ядро: shard.yml
  # ------------------------------------------------------------------

  class ShardMeta
    # One `binaries:` entry — carat's own delivery contract (shards'
    # executables:/targets: say nothing about how to build):
    #   binaries:
    #     tool:
    #       main: src/tool.cr          # default: src/<name>.cr
    #       prebuild: rake build:native # command in the shard root
    #       flags:                      # crystal build flags
    #         "*": [--something]
    #         darwin: [-DSOME=1]
    #       link_flags:                 # linker flags, per-OS where they differ
    #         "*": [-Llib]
    #         linux: [lib/libfoo.a]
    #         windows: [/LIBPATH:lib]
    class BinarySpec
      getter name : String
      getter main : String
      getter prebuild : String?
      getter flags : YAML::Any?
      getter link_flags : YAML::Any?

      def initialize(@name : String, @main : String, @prebuild : String?,
                     @flags : YAML::Any?, @link_flags : YAML::Any?)
      end
    end

    getter name : String
    getter version : String
    getter binaries : Array(BinarySpec)
    getter examples : Array(BinarySpec)

    def initialize(@name : String, @version : String,
                   @binaries : Array(BinarySpec), @examples : Array(BinarySpec))
    end

    def self.from_file(path : String) : self
      unless File.exists?(path)
        raise Error.new("shard.yml not found: #{path}")
      end
      from_yaml(File.read(path))
    end

    def self.from_yaml(content : String) : self
      doc = YAML.parse(content) rescue raise Error.new("invalid shard.yml")
      name = doc["name"]?.try &.as_s?
      raise Error.new("shard.yml has no name") unless name
      version = doc["version"]?.try &.as_s? || "0.0.0"
      new(name, version, parse_section(doc, "binaries"), parse_section(doc, "examples"))
    end

    # A `binaries:`/`examples:` section is a list of names (main defaults
    # to src/<name>.cr) or a mapping name -> spec
    # (main/prebuild/flags/link_flags).
    private def self.parse_section(doc : YAML::Any, key : String) : Array(BinarySpec)
      node = doc[key]?
      specs = [] of BinarySpec
      return specs if node.nil?
      case node.raw
      when Array
        node.as_a.each do |item|
          name = item.as_s
          specs << BinarySpec.new(name, File.join("src", "#{name}.cr"), nil, nil, nil)
        end
      when Hash
        node.as_h.each do |key, spec|
          name = key.as_s
          case spec.raw
          when String
            specs << BinarySpec.new(name, spec.as_s, nil, nil, nil)
          when Hash
            main = spec["main"]?.try(&.as_s?) || File.join("src", "#{name}.cr")
            prebuild = spec["prebuild"]?.try &.as_s?
            specs << BinarySpec.new(name, main, prebuild, spec["flags"]?, spec["link_flags"]?)
          end
        end
      end
      specs
    end
  end

  # OS family for the binaries: selectors; "macos" is an alias of "darwin".
  def self.os_family : String
    {% if flag?(:windows) %}
      "windows"
    {% elsif flag?(:darwin) %}
      "darwin"
    {% else %}
      "linux"
    {% end %}
  end

  # A flags:/link_flags: value: a plain list applies to every OS; a mapping
  # selects by OS family — exact match, then alias (macos for darwin),
  # then "*"; first hit wins.
  def self.select_flag_list(node : YAML::Any?, os : String = os_family) : Array(String)
    return [] of String if node.nil?
    case node.raw
    when Array
      node.as_a.map &.to_s
    when Hash
      selected = node[os]?
      selected = node["macos"]? if selected.nil? && os == "darwin"
      selected = node["*"]? if selected.nil?
      selected.try(&.as_a?).try(&.map &.to_s) || [] of String
    else
      [] of String
    end
  end

  # Рекурсивный сбор флагов сборки из зависимостей: библиотека (например,
  # C-привязка) может объявить top-level flags:/link_flags: в своём
  # shard.yml — carat подхватывает их при сборке бинарников любого шарда,
  # который от неё зависит. Источник — lib/**/shard.yml (после shards
  # install; у глобальной установки lib/ появляется через prebuild).
  # Glob не следует симлинкам — циклов в раскладке shards не будет.
  def self.collect_dep_flags(dir : String, os : String) : {Array(String), Array(String)}
    flags = [] of String
    link_flags = [] of String
    Dir.glob(File.join(dir, "lib", "**", "shard.yml")).sort.each do |path|
      doc = YAML.parse(File.read(path)) rescue next
      flags.concat(select_flag_list(doc["flags"]?, os))
      link_flags.concat(select_flag_list(doc["link_flags"]?, os))
    end
    {flags, link_flags}
  end

  # ------------------------------------------------------------------
  # Ядро: резолв источника
  # ------------------------------------------------------------------

  class Source
    enum Kind
      Local
      Git
    end

    getter kind : Kind
    getter location : String
    getter name : String? # подсказка имени (repo для owner/repo)

    def initialize(@kind : Kind, @location : String, @name : String? = nil)
    end
  end

  def self.resolve_source(src : String) : Source
    if File.directory?(src)
      Source.new(Source::Kind::Local, File.expand_path(src))
    elsif src.starts_with?("git@") || (src =~ /\A(?:https?|git|ssh|file):\/\//)
      name = src.chomp("/").split('/').last?.try &.gsub(/\.git\$/, "")
      Source.new(Source::Kind::Git, src, name)
    elsif src.count('/') == 1
      owner, repo = src.split('/', 2)
      Source.new(Source::Kind::Git, "https://github.com/#{owner}/#{repo}.git", repo)
    else
      # голое имя → конвенция github.com/<name>/<name>
      Source.new(Source::Kind::Git, "https://github.com/#{src}/#{src}.git", src)
    end
  end

  # ------------------------------------------------------------------
  # Ядро: валидация артефактов по magic bytes
  # ------------------------------------------------------------------

  module Artifact
    MACHO_MAGICS = [
      Bytes[0xFE, 0xED, 0xFA, 0xCE], # Mach-O 32 BE
      Bytes[0xFE, 0xED, 0xFA, 0xCF], # Mach-O 64 BE
      Bytes[0xCE, 0xFA, 0xED, 0xFE], # Mach-O 32 LE
      Bytes[0xCF, 0xFA, 0xED, 0xFE], # Mach-O 64 LE
    ]

    def self.binary?(path : String) : Bool
      File.open(path) do |f|
        buf = Bytes.new(4)
        n = f.read(buf)
        return false if n < 2
        return true if n >= 4 && buf[0] == 0x7F && buf[1] == 0x45 && buf[2] == 0x4C && buf[3] == 0x46 # ELF
        return true if buf[0] == 0x4D && buf[1] == 0x5A                                                 # MZ (PE)
        n >= 4 && MACHO_MAGICS.any? { |m| m == buf[0, 4] }
      end
    end
  end

  # ------------------------------------------------------------------
  # Ядро: сборка binaries
  # ------------------------------------------------------------------

  # mold (and some ld setups) do not open relative paths from --link-flags:
  # a relative archive/dir reference is rewritten against the shard root —
  # only when it actually exists there (real file/dir, not a random flag).
  private def self.absolutize_link_flags(flags : Array(String), dir : String) : Array(String)
    flags.map do |flag|
      prefix = {"-L" => 2, "/LIBPATH:" => 9}.find { |p, _| flag.starts_with?(p) }
      if prefix
        p, n = prefix
        rest = flag[n..]
        File.directory?(File.join(dir, rest)) && !Path[rest].absolute? ? p + File.expand_path(rest, dir) : flag
      elsif !Path[flag].absolute? && File.file?(File.join(dir, flag))
        File.expand_path(flag, dir)
      else
        flag
      end
    end
  end

  # Проверка записываемости каталога ДО клонирования и release-сборки:
  # probe-файл создаётся и удаляется. На Unix прикладная ошибка — EACCES
  # от mkdir или File.write; обе проходят как File::Error/Errno.
  def self.check_writable_dir(dir : String) : Nil
    begin
      Dir.mkdir_p(dir)
      probe = File.join(dir, ".carat-probe-#{Random::Secure.hex(4)}")
      File.write(probe, "")
      File.delete(probe)
    rescue e : File::Error
      hint = {% if flag?(:windows) %}
               "run your terminal as Administrator"
             {% else %}
               "rerun with sudo, or install without --system"
             {% end %}
      raise Error.new("no write permission for #{dir} (#{e.message}) — #{hint}")
    end
  end

  def self.build_binaries(meta : ShardMeta, dir : String, bin_dir : String) : Array(String)
    if meta.binaries.empty?
      raise Error.new("#{meta.name}: no binaries: entry in shard.yml — nothing to build")
    end
    build_specs(meta, meta.binaries, dir, bin_dir)
  end

  # The optional examples: section — same build pipeline as binaries:, but
  # only built with --with-examples (never on a plain `carat install`).
  def self.build_examples(meta : ShardMeta, dir : String, examples_dir : String) : Array(String)
    build_specs(meta, meta.examples, dir, examples_dir)
  end

  private def self.build_specs(meta : ShardMeta, specs : Array(ShardMeta::BinarySpec),
                               dir : String, out_dir : String) : Array(String)
    unless shell.which("crystal")
      raise Error.new("crystal compiler not found in PATH")
    end
    Dir.mkdir_p(out_dir)
    os = os_family
    dep_flags, dep_link_flags = collect_dep_flags(dir, os)
    unless dep_flags.empty? && dep_link_flags.empty?
      puts "Dep flags (lib/, uniq): flags=#{dep_flags.uniq.inspect} link_flags=#{dep_link_flags.uniq.inspect}"
    end
    built = [] of String
    specs.each do |bin|
      entry = File.join(dir, bin.main)
      unless File.exists?(entry)
        raise Error.new("#{meta.name}: main for binary #{bin.name} not found: #{bin.main}")
      end
      if prebuild = bin.prebuild
        puts "Prebuild (#{bin.name}): #{prebuild}"
        unless shell.run_command(prebuild, dir)
          raise Error.new("prebuild failed for #{bin.name}: #{prebuild}")
        end
      end
      target = File.join(out_dir, bin.name)
      overwritten = File.exists?(target)
      if overwritten
        warning("WARNING: OVERWRITING WITH NEW BINARY: #{target}")
      end
      puts "Building #{bin.name} (#{meta.name} #{meta.version}, release)..."
      # Свои флаги бинарника + флаги зависимостей, uniq с сохранением порядка
      # (свои первыми — селекторы зависимостей их не перекрывают).
      flags = (select_flag_list(bin.flags, os) + dep_flags).uniq
      link_flags = absolutize_link_flags((select_flag_list(bin.link_flags, os) + dep_link_flags).uniq, dir)
      args = ["build", "--release", "--no-color"] + flags
      args += ["--link-flags", link_flags.join(' ')] unless link_flags.empty?
      # Сборка во временный файл + rename: прямой -o поверх запущенного
      # бинарника падает с ETXTBSY (актуально для `carat update carat`).
      staged = "#{target}.new"
      args += ["-o", staged, bin.main]
      unless shell.run("crystal", args, dir)
        File.delete(staged) if File.exists?(staged)
        raise Error.new("build failed: #{bin.name}")
      end
      unless Artifact.binary?(staged)
        File.delete(staged)
        raise Error.new("#{staged}: artifact is not a native executable (magic bytes check failed)")
      end
      {% if flag?(:windows) %}
        File.delete(target) if File.exists?(target) # rename поверх существующего не работает
      {% end %}
      File.rename(staged, target)
      if overwritten
        logger.log("overwrite #{target}: #{meta.name} #{meta.version} replaced previous binary")
      end
      built << target
    end
    built
  end

  # ------------------------------------------------------------------
  # Глобальная установка
  # ------------------------------------------------------------------

  class GlobalInstaller
    def initialize(@src : String, @with_examples : Bool = false, @system : Bool = false)
    end

    def install : Nil
      source = Carat.resolve_source(@src)
      Paths.ensure_global_dirs
      bin_dir = target_bin_dir
      meta, staged = stage(source)
      previous = installed_version(meta.name)
      store = promote(meta, staged)
      Carat.build_binaries(meta, store, bin_dir)
      build_examples(meta, store)
      File.write(Paths.current_pointer(meta.name), meta.version)
      Carat.logger.log("install #{meta.name} #{meta.version} from #{source.location} to #{bin_dir} (previous: #{previous || "none"})")
      after_system_install(bin_dir)
      puts "Installed #{meta.name} #{meta.version} -> #{bin_dir}"
    end

    def update : Nil
      source = Carat.resolve_source(@src)
      Paths.ensure_global_dirs
      bin_dir = target_bin_dir
      meta, staged = stage(source)
      installed = installed_version(meta.name)
      unless installed
        FileUtils.rm_rf(staged)
        raise Error.new("#{meta.name} is not installed globally; run: carat install #{@src}")
      end
      cmp = SemVer.parse(meta.version) <=> SemVer.parse(installed)
      if cmp == 0
        FileUtils.rm_rf(staged)
        puts "#{meta.name} #{installed} is up to date"
        return
      end
      if cmp < 0
        FileUtils.rm_rf(staged)
        puts "Remote #{meta.name} #{meta.version} is older than installed #{installed}; nothing to do"
        return
      end
      puts "Updating #{meta.name} #{installed} -> #{meta.version}"
      store = promote(meta, staged)
      Carat.build_binaries(meta, store, bin_dir)
      build_examples(meta, store)
      File.write(Paths.current_pointer(meta.name), meta.version)
      Carat.logger.log("update #{meta.name} #{installed} -> #{meta.version} from #{source.location}")
      after_system_install(bin_dir)
      puts "Updated #{meta.name} #{meta.version} -> #{bin_dir}"
    end

    # Каталог назначения: --system кладёт бинарники системно; стор версий и
    # current-указатель в любом случае остаются в ~/.carat/shards.
    private def target_bin_dir : String
      dir = @system ? Paths.system_bin_dir : Paths.bin_dir
      Carat.check_writable_dir(dir) if @system
      dir
    end

    # Windows + --system: каталог установки нужно добавить в системный
    # (Machine) PATH — как rake install, но на уровне машины. Идемпотентно;
    # неудача не фатальна (бинарники уже установлены).
    {% if flag?(:windows) %}
      private def after_system_install(bin_dir : String) : Nil
        return unless @system
        script = <<~PS
          $bin = '#{bin_dir.gsub("/", "\\")}'
          $path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
          if (-not (($path -split ';') -contains $bin)) {
            [Environment]::SetEnvironmentVariable('Path', ($path + ';' + $bin), 'Machine')
            Write-Output "PATH: added $bin to the system PATH"
          }
        PS
        unless Carat.shell.run("powershell", ["-NoProfile", "-Command", script.strip], nil)
          Carat.warning("WARNING: could not add #{bin_dir} to the system PATH — add it manually")
        end
      end
    {% else %}
      private def after_system_install(bin_dir : String) : Nil
      end
    {% end %}

    # --with-examples: build the optional examples: section too, into
    # ~/.carat/examples (separate from the PATH-facing bin dir).
    private def build_examples(meta : ShardMeta, store : String) : Nil
      return unless @with_examples
      if meta.examples.empty?
        puts "#{meta.name}: no examples: entry in shard.yml, skipping examples"
        return
      end
      built = Carat.build_examples(meta, store, Paths.examples_dir)
      Carat.logger.log("examples #{meta.name} #{meta.version} -> #{Paths.examples_dir} (#{built.map { |p| File.basename(p) }.join(", ")})")
      puts "Examples -> #{Paths.examples_dir}"
    end

    private def stage(source : Source) : {ShardMeta, String}
      case source.kind
      in Source::Kind::Local
        meta = ShardMeta.from_file(File.join(source.location, "shard.yml"))
        staged = File.join(Paths.tmp_dir, "#{meta.name}-#{Random::Secure.hex(4)}")
        FileUtils.cp_r(source.location, staged)
        {meta, staged}
      in Source::Kind::Git
        hint = source.name || "shard"
        staged = File.join(Paths.tmp_dir, "#{hint}-#{Random::Secure.hex(4)}")
        puts "Cloning #{source.location}..."
        unless Carat.shell.run("git", ["clone", "--quiet", "--depth", "1", source.location, staged], nil)
          FileUtils.rm_rf(staged) if Dir.exists?(staged)
          raise Error.new("git clone failed: #{source.location}")
        end
        meta = ShardMeta.from_file(File.join(staged, "shard.yml"))
        {meta, staged}
      end
    end

    # Перенос staging-каталога в стор версий ~/.carat/shards/<name>/<ver>/
    private def promote(meta : ShardMeta, staged : String) : String
      store = Paths.shard_dir(meta.name, meta.version)
      FileUtils.rm_rf(store) if Dir.exists?(store)
      Dir.mkdir_p(File.dirname(store))
      File.rename(staged, store)
      store
    end

    private def installed_version(name : String) : String?
      pointer = Paths.current_pointer(name)
      File.exists?(pointer) ? File.read(pointer).strip : nil
    end
  end

  # ------------------------------------------------------------------
  # Проектная установка (аналог bundle install + binstubs)
  # ------------------------------------------------------------------

  class ProjectInstaller
    def initialize(@shards_command : String = "install", @with_examples : Bool = false)
    end

    def run : Nil
      shard_yml = File.join(Dir.current, "shard.yml")
      unless File.exists?(shard_yml)
        hint = @shards_command == "update" ? "carat update <src>" : "carat install <src>"
        raise Error.new("no shard.yml in #{Dir.current} (for a global install use: #{hint})")
      end
      unless Carat.shell.which("shards")
        raise Error.new("shards not found in PATH")
      end
      meta = ShardMeta.from_file(shard_yml)
      puts "Running shards #{@shards_command}..."
      unless Carat.shell.run("shards", [@shards_command], Dir.current)
        # shards' own hint says `shards update` — in a carat project the
        # equivalent is `carat update` (shards update + rebuild .carat/bin).
        raise Error.new("shards #{@shards_command} failed — try: carat update " \
                        "(runs `shards update`, then rebuilds ./.carat/bin)")
      end
      if meta.binaries.empty?
        # a library project (no binaries) is a legitimate carat install
        puts "No binaries entry in shard.yml, skipping"
        Carat.logger.log("project #{@shards_command} #{meta.name} #{meta.version} -> no binaries, nothing to build")
        return
      end
      bin_dir = Paths.project_bin
      built = Carat.build_binaries(meta, Dir.current, bin_dir)
      Carat.logger.log("project #{@shards_command} #{meta.name} #{meta.version} -> #{bin_dir} (#{built.map { |p| File.basename(p) }.join(", ")})")
      puts "Installed #{meta.name} #{meta.version} -> #{bin_dir}"
      return unless @with_examples
      if meta.examples.empty?
        puts "#{meta.name}: no examples: entry in shard.yml, skipping examples"
        return
      end
      examples_dir = Paths.project_examples
      built = Carat.build_examples(meta, Dir.current, examples_dir)
      Carat.logger.log("project examples #{@shards_command} #{meta.name} #{meta.version} -> #{examples_dir} (#{built.map { |p| File.basename(p) }.join(", ")})")
      puts "Examples -> #{examples_dir}"
    end
  end

  # ------------------------------------------------------------------
  # exec (аналог bundle exec)
  # ------------------------------------------------------------------

  def self.exec_command(command : String, args : Array(String)) : Nil
    bin = Paths.project_bin
    unless Dir.exists?(bin)
      raise Error.new("#{bin} not found; run `carat install` in the project first")
    end
    env_hash = ENV.to_h
    current = env_hash["PATH"]? || ""
    new_path = "#{bin}#{env.path_separator}#{current}"
    # Process.exec с env не ищет команду по PATH — резолвим сами
    resolved = executable_file?(File.join(bin, command)) ? File.join(bin, command) : shell.which(command)
    raise Error.new("command not found: #{command}") unless resolved
    env_hash["PATH"] = new_path
    Process.exec(resolved, args, env: env_hash)
  end

  # ------------------------------------------------------------------
  # CLI
  # ------------------------------------------------------------------

  USAGE = <<-TEXT
    carat #{VERSION} — global binary installer for Crystal shards

    Usage:
      carat install <src>   Global install: clone -> build -> binaries in ~/.carat/bin
                            <src>: owner/repo | name | git URL | local directory
      carat install .       Global install of the shard in the current directory
                            (local shard development)
      carat install         In a project with shard.yml: shards install + build
                            binaries into ./.carat/bin
      carat update <src>    Update globally installed shard if remote version is newer
      carat update          In a project: delegates to shards update + rebuild
                            binaries into ./.carat/bin
      carat exec <cmd> ...  Run <cmd> with ./.carat/bin prepended to PATH
      carat completion install
                            Shell autocompletion (bash/fish; zsh hint)

    Options:
      --with-examples      Also build the optional examples: section
                            (global: ~/.carat/examples, project: ./.carat/examples)
      --system             Install binaries into the system dir instead of
                            ~/.carat/bin (Unix: /usr/local/bin, Windows:
                            %ProgramFiles%\\carat\\bin + system PATH).
                            Needs root/Administrator — fails fast with a
                            clear error if not.

    Directories:
      ~/.carat/bin/                  global binaries (only entry points)
      ~/.carat/examples/             global example binaries (--with-examples)
      ~/.carat/shards/<name>/<ver>/  global source store, per version
      ~/.carat/shards/<name>/current installed version pointer
      ~/.carat/logs/carat.log        install/overwrite/update audit log
      ./.carat/bin/                  project binaries
      ./.carat/examples/             project example binaries (--with-examples)
  TEXT

  # Подкоманды для автокомплита; "__complete" скрытая — не показывается.
  COMMANDS = ["install", "update", "exec", "completion"]

  def self.run(argv : Array(String)) : Nil
    # bash `complete -C carat carat` protocol: bash runs us with COMP_LINE/
    # COMP_POINT in the env and argv ["carat", <cur>, <prev>]. Intercepted
    # before normal parsing — a half-typed word must not error. Hidden.
    if ENV.has_key?("COMP_LINE") && argv.size == 3 && argv[0]? == "carat"
      return complete_c
    end
    # The same candidates from words on the command line, for fish and
    # manual use: carat __complete <words...> (last word = one being
    # completed).
    return complete(argv[1..]) if argv[0]? == "__complete"

    case command = argv[0]?
    when "install"
      rest = argv[1..]
      with_examples = !rest.delete("--with-examples").nil?
      system = !rest.delete("--system").nil?
      if src = rest[0]?
        GlobalInstaller.new(src, with_examples, system).install
      else
        raise Error.new("--system is only valid for global installs (carat install <src>)") if system
        ProjectInstaller.new("install", with_examples).run
      end
    when "update"
      rest = argv[1..]
      with_examples = !rest.delete("--with-examples").nil?
      system = !rest.delete("--system").nil?
      if src = rest[0]?
        GlobalInstaller.new(src, with_examples, system).update
      else
        raise Error.new("--system is only valid for global installs (carat update <src>)") if system
        ProjectInstaller.new("update", with_examples).run
      end
    when "exec"
      cmd = argv[1]?
      raise Error.new("usage: carat exec <cmd> [args]") unless cmd
      args = argv.size > 2 ? argv[2..] : [] of String
      exec_command(cmd, args)
    when "completion"
      case argv[1]?
      when "install"
        completion_install
      else
        raise Error.new("usage: carat completion install")
      end
    when "--version", "-v", "version"
      puts VERSION
    when "--help", "-h", "help", nil
      puts USAGE
    else
      STDERR.puts "carat: unknown command: #{command}"
      STDERR.puts USAGE
      exit 1
    end
  end

  # ------------------------------------------------------------------
  # Автокомплит (по образцу twinshot): bash дергает сам бинарник через
  # `complete -C carat carat`, fish — через `carat __complete`.
  # ------------------------------------------------------------------

  private def self.complete_c : Nil
    line = ENV["COMP_LINE"]? || ""
    point = ENV["COMP_POINT"]?.try(&.to_i?) || line.size
    before = line[0, Math.min(point, line.size)]
    words = before.split.reject(&.empty?)
    words = words[1..]? || [] of String # drop the "carat" word
    words << "" if before.empty? || before.ends_with?(' ')
    complete(words)
  end

  # Печатает кандидатов по набору слов командной строки: последнее слово
  # дозаполняется, остальное — уже набранное. Фильтруем по префиксу и
  # исключаем точное совпадение (иначе bash `complete -C` дописывает
  # кандидата к уже полностью набранному слову при каждом TAB).
  private def self.complete(words : Array(String)) : Nil
    current = words.last? || ""
    typed = words.size > 1 ? words[0...-1] : [] of String
    begin
      candidates_for(typed).each { |c| puts c if c.starts_with?(current) && c != current }
    rescue IO::Error
      # вывод ушел в закрытый пайп (| head) — это нормальный выход
    end
  end

  private def self.candidates_for(typed : Array(String)) : Array(String)
    case typed.first?
    when nil          then COMMANDS + ["--help", "--version"]
    when "exec"       then typed.size == 1 ? exec_candidates : [] of String
    when "install"    then typed.size == 1 ? ["--with-examples", "--system"] : [] of String
    when "update"     then installed_shards + ["--with-examples", "--system"]
    when "completion" then ["install"]
    else                   [] of String
    end
  end

  # carat exec <TAB>: только проектные бинарники из ./.carat/bin текущего
  # каталога (сам carat исключён). exec — проектная команда, глобальные
  # бинарники и весь PATH не предлагаются.
  private def self.exec_candidates : Array(String)
    candidates = [] of String
    dir = Paths.project_bin
    if Dir.exists?(dir)
      Dir.children(dir).sort.each do |name|
        next if name == "carat" # carat exec carat — не кандидат
        candidates << name if executable_file?(File.join(dir, name))
      end
    end
    candidates
  end

  # carat update <TAB>: глобально установленные шарды.
  private def self.installed_shards : Array(String)
    dir = Paths.shards_dir
    return [] of String unless Dir.exists?(dir)
    Dir.children(dir).sort.select { |name| File.exists?(Paths.current_pointer(name)) }
  end

  # `complete -C carat carat` into the XDG bash-completion dir — no rc
  # edits, live on the first TAB in a new shell. fish gets a driver that
  # calls `carat __complete`. zsh: bashcompinit hint (no standard dir).
  private def self.completion_install : Nil
    {% if flag?(:windows) %}
      puts "Shell completion is not supported on Windows yet"
      return
    {% end %}

    xdg = ENV["XDG_DATA_HOME"]?
    data_home = xdg && xdg.starts_with?('/') ? xdg : File.join(env.home, ".local", "share")
    bash_dir = File.join(data_home, "bash-completion", "completions")
    Dir.mkdir_p(bash_dir)
    bash_file = File.join(bash_dir, "carat")
    File.write(bash_file, "complete -C carat carat\n")
    puts "Wrote #{bash_file}"

    if shell.which("fish")
      fish_dir = File.join(env.home, ".config", "fish", "completions")
      Dir.mkdir_p(fish_dir)
      File.write(File.join(fish_dir, "carat.fish"),
        %(complete -c carat -f -a '(carat __complete (commandline -opc)[2..-1] "")'\n))
      puts "Wrote #{File.join(fish_dir, "carat.fish")}"
    end

    if shell.which("zsh") || File.exists?(File.join(env.home, ".zshrc"))
      puts "zsh: add to ~/.zshrc:\n  autoload -U +X bashcompinit && bashcompinit\n  complete -C carat carat"
    end
    puts "Completion is live in a new shell (loaded on your first TAB)."
  end
end

begin
  Carat.run(ARGV)
rescue e : Carat::Error
  STDERR.puts Carat.paint("carat: #{e.message}", :red)
  exit 1
end
