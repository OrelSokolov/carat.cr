# Глобальная установка: staging (клон по тегу/HEAD или локальная копия),
# identity (version / version+git.commit.<sha>), стор версий с current-
# указателем, сборка + apps, update по semver/коммиту.

module Carat
  # ------------------------------------------------------------------
  # Глобальная установка
  # ------------------------------------------------------------------

  class GlobalInstaller
    # release=false — dev-сборка (без --release);
    # only_shards=true — только клонирование и `shards install`, без сборки
    # бинарников (`carat only install`);
    # head=true — всегда HEAD дефолтной ветки (`carat install head <src>`),
    # игнорируя релизные теги — свежий master, пускай экспериментальный;
    # version — точная версия (`carat install <src> --version 1.1.0`, как
    # `gem install foo --version`): ставится тег с этой версией вместо
    # старшего semver-тега.
    def initialize(@src : String, @with_examples : Bool = false, @system : Bool = false,
                   @release : Bool = true, @only_shards : Bool = false, @head : Bool = false,
                   @version : String? = nil)
    end

    def install : Nil
      source = Carat.resolve_source(@src)
      Paths.ensure_global_dirs
      bin_dir = target_bin_dir
      meta, staged, identity = stage(source)
      previous = installed_version(meta.name)
      store = promote(meta, staged, identity)
      Carat.install_dependencies(meta, store)
      build_all(meta, store, bin_dir)
      File.write(Paths.current_pointer(meta.name), identity)
      Carat.logger.log("install #{meta.name} #{identity} from #{source.location} to #{bin_dir} (previous: #{previous || "none"})")
      after_system_install(bin_dir)
      if @only_shards
        puts "Installed shards of #{meta.name} #{identity} -> #{store}"
      else
        puts "Installed #{meta.name} #{identity} -> #{bin_dir}"
      end
    end

    def update : Nil
      source = Carat.resolve_source(@src)
      Paths.ensure_global_dirs
      bin_dir = target_bin_dir
      meta, staged, identity = stage(source)
      installed = installed_version(meta.name)
      unless installed
        FileUtils.rm_rf(staged)
        raise Error.new("#{meta.name} is not installed globally; run: carat install #{@src}")
      end
      # Identity совпала — стоит ровно тот же тег/коммит, выходим. Дальше
      # semver по базовой версии (build-метаданные +git.commit.<sha> в
      # сравнении не участвуют): старший тег обновляет, младший — не
      # даунгрейдит. Равная версия с другим identity — master уехал без
      # bump'а version: обновляемся по изменившемуся коммиту.
      if identity == installed
        FileUtils.rm_rf(staged)
        puts "#{meta.name} #{installed} is up to date"
        return
      end
      cmp = SemVer.parse(meta.version) <=> SemVer.parse(installed)
      if cmp < 0
        FileUtils.rm_rf(staged)
        puts "Remote #{meta.name} #{identity} is older than installed #{installed}; nothing to do"
        return
      end
      puts "Updating #{meta.name} #{installed} -> #{identity}"
      store = promote(meta, staged, identity)
      Carat.install_dependencies(meta, store)
      build_all(meta, store, bin_dir)
      File.write(Paths.current_pointer(meta.name), identity)
      Carat.logger.log("update #{meta.name} #{installed} -> #{identity} from #{source.location}")
      after_system_install(bin_dir)
      if @only_shards
        puts "Updated shards of #{meta.name} #{identity} -> #{store}"
      else
        puts "Updated #{meta.name} #{identity} -> #{bin_dir}"
      end
    end

    # Сборка бинарников (и примеров); в режиме only — пропускается, ставятся
    # только зависимости.
    private def build_all(meta : ShardMeta, store : String, bin_dir : String) : Nil
      return if @only_shards
      Carat.build_binaries(meta, store, bin_dir, @release)
      build_examples(meta, store)
      # GUI-приложения (`app:`) переезжают из bin_dir в ~/.carat/apps/<name>/
      # и получают иконку + нативный лаунчер.
      Apps.install(meta, store, bin_dir)
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
    # PS-скрипт собирается из строк: heredoc внутри {% if %}-ветки не
    # разворачивается компилятором (unexpected token <<).
    {% if flag?(:windows) %}
      private def after_system_install(bin_dir : String) : Nil
        return unless @system
        script = [
          "$bin = '#{bin_dir.gsub("/", "\\")}'",
          "$path = [Environment]::GetEnvironmentVariable('Path', 'Machine')",
          "if (-not (($path -split ';') -contains $bin)) {",
          "  [Environment]::SetEnvironmentVariable('Path', ($path + ';' + $bin), 'Machine')",
          %(  Write-Output "PATH: added $bin to the system PATH"),
          "}",
        ].join("\n")
        unless Carat.shell.run("powershell", ["-NoProfile", "-Command", script], nil)
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

    # Клонирование в staging-каталог. Возвращает {meta, staged, identity}:
    # identity — то, что устанавливаем и пишем в current-указатель. Для
    # релизного тега это version из shard.yml (стабильно, как в shard.lock);
    # для HEAD — version+git.commit.<sha> (нотация shard.lock для веточных
    # зависимостей): разный коммит master'а = разный identity, и update видит
    # движение ветки даже без bump'а version. По умолчанию резолв как у
    # shards: старший semver-тег, HEAD дефолтной ветки — только если тегов
    # нет; head-режим всегда берёт HEAD.
    private def stage(source : Source) : {ShardMeta, String, String}
      # --version: точный тег вместо старшего; конфликтует с head и имеет
      # смысл только для git-источников (локальный каталог не версионирован).
      if @version
        raise Error.new("--version cannot be combined with head") if @head
        if source.kind.local?
          raise Error.new("--version is only valid for git sources: #{source.location} is a local directory")
        end
      end
      case source.kind
      in Source::Kind::Local
        meta = ShardMeta.from_file(File.join(source.location, "shard.yml"))
        staged = File.join(Paths.tmp_dir, "#{meta.name}-#{Random::Secure.hex(4)}")
        Carat.copy_tree(source.location, staged)
        {meta, staged, meta.version}
      in Source::Kind::Git
        tag = if @head
                nil
              elsif v = @version
                resolve_tag(source.location, v)
              else
                latest_tag(source.location)
              end
        hint = source.name || "shard"
        staged = File.join(Paths.tmp_dir, "#{hint}-#{Random::Secure.hex(4)}")
        puts "Cloning #{source.location} (#{tag || "default branch HEAD"})..."
        clone_args = ["-c", "advice.detachedHead=false", "clone", "--quiet", "--depth", "1"]
        clone_args.concat(["--branch", tag]) if tag
        clone_args << source.location << staged
        unless Carat.shell.run("git", clone_args, nil)
          FileUtils.rm_rf(staged) if Dir.exists?(staged)
          # git уже напечатал свою причину выше (вывод наследуется); сюда —
          # подсказка про самый частый случай приватного репозитория.
          # Авторизация делегирована git'у: ssh-ключи, credential helper
          # или https-токен работают как в любом другом git clone.
          raise Error.new("git clone failed: #{source.location}" \
                          " — for a private repository make sure git can authenticate" \
                          " (ssh key loaded, credential helper or https token)")
        end
        meta = ShardMeta.from_file(File.join(staged, "shard.yml"))
        if tag
          {meta, staged, meta.version}
        else
          sha = Carat.git(["rev-parse", "HEAD"], staged).try(&.strip) ||
                raise Error.new("git rev-parse failed in #{staged}")
          {meta, staged, "#{meta.version}+git.commit.#{sha[0, 10]}"}
        end
      end
    end

    # Все semver-теги репозитория: {имя тега => коммит}. Аннотированные теги
    # идут двумя строками: ^{} (peeled) указывает на сам коммит и перебивает
    # указатель тег-объекта. Нет подходящих тегов — пустый хэш.
    private def remote_tags(url : String) : Hash(String, String)
      refs = Carat.git(["ls-remote", "--tags", url]) || return {} of String => String
      tags = {} of String => String
      refs.each_line do |line|
        next unless match = line.match(/\A([0-9a-f]{40})\trefs\/tags\/([^^\s]+)(\^\{\})?\z/)
        sha, name, peeled = match[1], match[2], match[3]?
        next unless SemVer.parsable?(name)
        if peeled || !tags.has_key?(name)
          tags[name] = sha
        end
      end
      tags
    end

    # Старший semver-тег репозитория (резолв как у shards: git-зависимость
    # без версии — это последний релизный тег, а не HEAD ветки). Нет подходящих
    # тегов — nil, caller клонирует HEAD дефолтной ветки.
    private def latest_tag(url : String) : String?
      remote_tags(url).max_by? { |name, _| SemVer.parse(name) }.try(&.[0])
    end

    # Тег с точной версией для `--version` (как `gem install --version`):
    # имя тега нормализуется через SemVer (v-префикс, build-метаданные), то
    # есть `--version 1.1.0` находит и тег v1.1.0. Нет такого тега — ошибка
    # со списком доступных версий.
    private def resolve_tag(url : String, version : String) : String
      unless SemVer.parsable?(version)
        raise Error.new("invalid --version: #{version} (expected e.g. 1.1.0)")
      end
      wanted = SemVer.parse(version)
      tags = remote_tags(url)
      match = tags.keys.find { |name| SemVer.parse(name) == wanted }
      return match if match
      available = tags.keys.sort_by { |name| SemVer.parse(name) }.reverse.join(", ")
      raise Error.new("#{url}: no release tag for version #{version}" \
                      "#{available.empty? ? " (the repo has no release tags)" : " (available: #{available})"}")
    end

    # Перенос staging-каталога в стор версий ~/.carat/shards/<name>/<identity>/
    private def promote(meta : ShardMeta, staged : String, identity : String) : String
      store = Paths.shard_dir(meta.name, identity)
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
end
