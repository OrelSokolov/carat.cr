# Сборка binaries:/examples:: селекторы флагов по ОС, флаги из
# зависимостей (lib/**/shard.yml), prebuild-шаги, валидация артефактов
# по magic bytes, проверка записываемости каталога, shards install
# зависимостей глобальной установки.

module Carat
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
        return true if buf[0] == 0x4D && buf[1] == 0x5A                                               # MZ (PE)
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

  # A globally installed shard builds with `crystal build` directly, and
  # the compiler resolves bare requires from the project's lib/ — so the
  # dependency resolution the project mode delegates to `shards install`
  # must run here too: once, in the stored copy, before the first binary
  # is built. Dep-free shards skip it (nothing to resolve).
  def self.install_dependencies(meta : ShardMeta, dir : String) : Nil
    return unless meta.has_dependencies?
    unless shell.which("shards")
      raise Error.new("shards not found in PATH — needed to install dependencies of #{meta.name}")
    end
    puts "Installing dependencies of #{meta.name} (shards install)..."
    unless shell.run("shards", ["install"], dir)
      raise Error.new("shards install failed for #{meta.name}")
    end
  end

  # release=true → `--release` (= -O3 --single-module); release=false —
  # dev-режим: обычный `crystal build` без оптимизаций (быстрый кодоген).
  # warn_overwrite=false для проектной установки: перезапись ./.carat/bin —
  # нормальный цикл пересборки, WARNING только для глобальных каталогов,
  # где он защищает PATH от тихой подмены.
  # Общий prebuild секции — `all: prebuild:` в binaries:/examples:
  # (см. ShardMeta::Section): один раз, а не по разу на каждый бинарник.
  def self.build_binaries(meta : ShardMeta, dir : String, bin_dir : String,
                          release : Bool = true, warn_overwrite : Bool = true) : Array(String)
    if meta.binaries.empty?
      raise Error.new("#{meta.name}: no binaries: entry in shard.yml — nothing to build")
    end
    build_specs(meta, meta.binaries, dir, bin_dir, release, warn_overwrite)
  end

  # The optional examples: section — same build pipeline as binaries:, but
  # only built with --with-examples (never on a plain `carat install`).
  def self.build_examples(meta : ShardMeta, dir : String, examples_dir : String,
                          release : Bool = true, warn_overwrite : Bool = true) : Array(String)
    build_specs(meta, meta.examples, dir, examples_dir, release, warn_overwrite)
  end

  private def self.build_specs(meta : ShardMeta, section : ShardMeta::Section,
                               dir : String, out_dir : String, release : Bool,
                               warn_overwrite : Bool) : Array(String)
    unless shell.which("crystal")
      raise Error.new("crystal compiler not found in PATH")
    end
    Dir.mkdir_p(out_dir)
    os = os_family
    dep_flags, dep_link_flags = collect_dep_flags(dir, os)
    unless dep_flags.empty? && dep_link_flags.empty?
      puts "Dep flags (lib/, uniq): flags=#{dep_flags.uniq.inspect} link_flags=#{dep_link_flags.uniq.inspect}"
    end
    # `all: prebuild:` — общий шаг секции, один раз до сборки бинарников.
    if all_prebuild = section.all.try &.prebuild
      puts "Prebuild (all): #{all_prebuild}"
      unless shell.run_command(all_prebuild, dir)
        raise Error.new("prebuild failed: #{all_prebuild}")
      end
    end
    specs = section.specs
    # Проверка main-файлов до любых сборок: падать быстрее, чем через
    # N-й бинарник в очереди пула.
    specs.each do |bin|
      unless File.exists?(File.join(dir, bin.main))
        raise Error.new("#{meta.name}: main for binary #{bin.name} not found: #{bin.main}")
      end
    end
    # Побайнарные prebuild (ключ `each:` / собственный) — ДО пула:
    # это нативные шаги (rake/make) с инкрементальным состоянием, не
    # безопасным под конкурентным запуском.
    specs.each do |bin|
      if prebuild = bin.prebuild
        puts "Prebuild (#{bin.name}): #{prebuild}"
        unless shell.run_command(prebuild, dir)
          raise Error.new("prebuild failed for #{bin.name}: #{prebuild}")
        end
      end
    end
    jobs = specs.map do |bin|
      build = ->(env : Hash(String, String)) {
        build_one(meta, bin, dir, out_dir, release, warn_overwrite,
          os, dep_flags, dep_link_flags, env)
      }
      BuildPool::Job.new(bin.name, build)
    end
    BuildPool.new(dir, jobs).run
    specs.map { |bin| File.join(out_dir, bin.name) }
  end

  # Сборка одного бинарника в staged-файл + rename (прямой -o поверх
  # запущенного бинарника падает с ETXTBSY — актуально для
  # `carat update carat`). env — CRYSTAL_CACHE_DIR воркера.
  private def self.build_one(meta : ShardMeta, bin : ShardMeta::BinarySpec,
                             dir : String, out_dir : String, release : Bool,
                             warn_overwrite : Bool, os : String,
                             dep_flags : Array(String), dep_link_flags : Array(String),
                             env : Hash(String, String)) : Nil
    target = File.join(out_dir, bin.name)
    overwritten = File.exists?(target)
    if overwritten && warn_overwrite
      warning("WARNING: OVERWRITING WITH NEW BINARY: #{target}")
    end
    puts "Building #{bin.name} (#{meta.name} #{meta.version}, #{release ? "release" : "dev"})..."
    # Свои флаги бинарника + флаги зависимостей, uniq с сохранением порядка
    # (свои первыми — селекторы зависимостей их не перекрывают).
    flags = (select_flag_list(bin.flags, os) + dep_flags).uniq
    link_flags = absolutize_link_flags((select_flag_list(bin.link_flags, os) + dep_link_flags).uniq, dir)
    args = ["build", "--no-color"]
    args << "--release" if release
    args += flags
    args += ["--link-flags", link_flags.join(' ')] unless link_flags.empty?
    staged = "#{target}.new"
    args += ["-o", staged, bin.main]
    begin
      unless BuildPool.spawn_process("crystal", args, dir, env)
        raise Error.new("build failed: #{bin.name}")
      end
      unless Artifact.binary?(staged)
        raise Error.new("#{staged}: artifact is not a native executable (magic bytes check failed)")
      end
      {% if flag?(:windows) %}
        File.delete(target) if File.exists?(target) # rename поверх существующего не работает
      {% end %}
      File.rename(staged, target)
    ensure
      File.delete(staged) if File.exists?(staged)
    end
    if overwritten
      logger.log("overwrite #{target}: #{meta.name} #{meta.version} replaced previous binary")
    end
  end
end
