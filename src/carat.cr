# carat — глобальный установщик бинарников для Crystal-шардов.
#
# `carat install owner/repo` тащит шард с GitHub, собирает `binaries:`
# через `crystal build --release` и кладёт самодостаточные бинарники в ~/.carat/bin.
#
# Архитектура: порты и адаптеры (по образцу Egui::SystemPorts) — ядро не знает
# про ОС, платформенные различия живут в адаптерах, выбор — compile-time флаги.

require "yaml"
require "file_utils"

module Carat
  VERSION = "0.3.0"

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

    def initialize(@name : String, @version : String, @binaries : Array(BinarySpec))
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
      new(name, version, parse_binaries(doc))
    end

    # `binaries:` is a list of names (main defaults to src/<name>.cr) or a
    # mapping name -> spec (main/prebuild/flags/link_flags).
    private def self.parse_binaries(doc : YAML::Any) : Array(BinarySpec)
      node = doc["binaries"]?
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

  def self.build_binaries(meta : ShardMeta, dir : String, bin_dir : String) : Array(String)
    if meta.binaries.empty?
      raise Error.new("#{meta.name}: no binaries: entry in shard.yml — nothing to build")
    end
    unless shell.which("crystal")
      raise Error.new("crystal compiler not found in PATH")
    end
    Dir.mkdir_p(bin_dir)
    os = os_family
    built = [] of String
    meta.binaries.each do |bin|
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
      target = File.join(bin_dir, bin.name)
      overwritten = File.exists?(target)
      if overwritten
        puts "WARNING: OVERWRITING WITH NEW BINARY: #{target}"
      end
      puts "Building #{bin.name} (#{meta.name} #{meta.version}, release)..."
      args = ["build", "--release", "--no-color"] + select_flag_list(bin.flags, os)
      link_flags = absolutize_link_flags(select_flag_list(bin.link_flags, os), dir)
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
    def initialize(@src : String)
    end

    def install : Nil
      source = Carat.resolve_source(@src)
      Paths.ensure_global_dirs
      meta, staged = stage(source)
      previous = installed_version(meta.name)
      store = promote(meta, staged)
      Carat.build_binaries(meta, store, Paths.bin_dir)
      File.write(Paths.current_pointer(meta.name), meta.version)
      Carat.logger.log("install #{meta.name} #{meta.version} from #{source.location} (previous: #{previous || "none"})")
      puts "Installed #{meta.name} #{meta.version} -> #{Paths.bin_dir}"
    end

    def update : Nil
      source = Carat.resolve_source(@src)
      Paths.ensure_global_dirs
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
      Carat.build_binaries(meta, store, Paths.bin_dir)
      File.write(Paths.current_pointer(meta.name), meta.version)
      Carat.logger.log("update #{meta.name} #{installed} -> #{meta.version} from #{source.location}")
      puts "Updated #{meta.name} #{meta.version} -> #{Paths.bin_dir}"
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
    def initialize(@shards_command : String = "install")
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

    Directories:
      ~/.carat/bin/                  global binaries (only entry points)
      ~/.carat/shards/<name>/<ver>/  global source store, per version
      ~/.carat/shards/<name>/current installed version pointer
      ~/.carat/logs/carat.log        install/overwrite/update audit log
      ./.carat/bin/                  project binaries
  TEXT

  def self.run(argv : Array(String)) : Nil
    case command = argv[0]?
    when "install"
      if src = argv[1]?
        GlobalInstaller.new(src).install
      else
        ProjectInstaller.new("install").run
      end
    when "update"
      if src = argv[1]?
        GlobalInstaller.new(src).update
      else
        ProjectInstaller.new("update").run
      end
    when "exec"
      cmd = argv[1]?
      raise Error.new("usage: carat exec <cmd> [args]") unless cmd
      args = argv.size > 2 ? argv[2..] : [] of String
      exec_command(cmd, args)
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
end

begin
  Carat.run(ARGV)
rescue e : Carat::Error
  STDERR.puts "carat: #{e.message}"
  exit 1
end
