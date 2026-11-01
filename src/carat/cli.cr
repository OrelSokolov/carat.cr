# CLI: разбор аргументов (install/update/user/system/dev/only/shards/
# exec/completion/self), USAGE, автокомплит (bash complete -C, fish
# __complete), carat exec (PATH c ./.carat/bin).

module Carat
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
                            Resolves like shards: the latest release tag when
                            the repo has tags, otherwise the default branch HEAD
                            <src>: owner/repo | name | git URL (https://, ssh://,
                            git@host:path) | local directory
                            Private repos work too: auth is delegated to git
                            (ssh keys, credential helper, https token)
      carat install head <src>
                            Always the default branch HEAD (fresh master,
                            experimental): the install is pinned per commit
                            (version+git.commit.<sha>), so `carat update head`
                            follows every push, tagged or not
      carat install .       Global install of the shard in the current directory
                            (local shard development)
      carat install         In a project with shard.yml: shards install + build
                            binaries into ./.carat/bin
      carat update <src>    Update globally installed shard if remote identity
                            is newer (tag: semver decides; head: any new commit)
      carat update head <src>
                            Re-resolve the default branch HEAD and rebuild
      carat update          In a project: delegates to shards update + rebuild
                            binaries into ./.carat/bin
      carat user remove <name>
                            Remove a globally installed (user scope) shard:
                            binaries from ~/.carat/bin, examples, GUI apps
                            with their launchers, the source store and the
                            version pointer
      carat system remove <name>
                            Same for a --system install: removes binaries from
                            the system dir (/usr/local/bin,
                            %ProgramFiles%\\carat\\bin on Windows); examples,
                            apps and the store are cleaned the same way.
                            Needs root/Administrator — fails fast if not
      carat dev install     Like install, but builds without --release
                            (plain crystal build: faster codegen, for iteration)
      carat dev update      Same for update
      carat only install    Like install, but only installs shards (shards install),
                            no binary build
      carat only update     Same for update (shards update only)
                            (`shards` is a synonym of `only`: carat shards install)
      carat exec <cmd> ...  Run <cmd> with ./.carat/bin prepended to PATH
      carat completion install
                            Shell autocompletion (bash/fish; zsh hint)
      carat self install   Install-or-update carat itself from the canonical
                            repository (OrelSokolov/carat.cr)
      carat self update    The same thing (alias of carat self install)

    Options:
      --with-examples      Also build the optional examples: section
                            (global: ~/.carat/examples, project: ./.carat/examples)
      --system             Install binaries into the system dir instead of
                            ~/.carat/bin (Unix: /usr/local/bin, Windows:
                            %ProgramFiles%\\carat\\bin + system PATH).
                            Needs root/Administrator — fails fast with a
                            clear error if not.
      --version <ver>      Install a specific version (git release tag), like
                            `gem install gem --version`: carat install
                            owner/repo --version 1.1.0. Without it the latest
                            release tag is resolved (shards behavior)

    Directories:
      ~/.carat/bin/                  global binaries (only entry points)
      ~/.carat/examples/             global example binaries (--with-examples)
      ~/.carat/apps/<name>/          GUI apps (app: binaries + icons)
      ~/.carat/shards/<name>/<identity>/  global source store, per installed version
                            (tag: 1.2.3; HEAD: 1.2.3+git.commit.a1b2c3d4e5)
      ~/.carat/shards/<name>/current installed identity pointer (see above)
      ~/.carat/logs/carat.log        install/overwrite/update audit log
      ./.carat/bin/                  project binaries
      ./.carat/examples/             project example binaries (--with-examples)

    Desktop apps (GUI):
      A binary with a `launchers:` mapping in shard.yml gets desktop
      integration beyond the PATH entry:
        launchers:
          terminal: true    # default, always: binary in ~/.carat/bin
          menu: true        # application menu (.desktop / Start Menu /
                            # ~/Applications .app bundle on macOS)
          desktop: true     # shortcut on the desktop, in addition to menu
      The icon comes from `assets:appicon:` (PNG or SVG, checked by magic
      bytes); no conversion pipeline is needed — .ico/.icns wrap the PNG
      as a container. The app itself knows nothing about carat: its assets
      live next to the binary (portable-app convention).
  TEXT

  # Подкоманды для автокомплита; "__complete" скрытая — не показывается.
  COMMANDS = ["install", "update", "user", "system", "dev", "only", "shards", "exec", "completion", "self"]

  # Канонический репозиторий carat — источник для `carat self ...`.
  CARAT_SOURCE = "OrelSokolov/carat.cr"

  # `--flag value` / `--flag=value`: достаёт значение флага из аргументов и
  # убирает его (и значение) из списка. Флага нет — nil.
  private def self.option_value(rest : Array(String), flag : String) : String?
    if i = rest.index(flag)
      rest.delete_at(i)
      value = rest[i]?
      raise Error.new("#{flag} requires a value (#{flag} 1.1.0)") unless value
      rest.delete_at(i)
      value
    elsif i = rest.index { |a| a.starts_with?("#{flag}=") }
      value = rest[i][(flag.size + 1)..]
      raise Error.new("#{flag} requires a value (#{flag} 1.1.0)") if value.empty?
      rest.delete_at(i)
      value
    end
  end

  # `carat self install` / `carat self update` — install-or-update самого carat
  # из канонического репозитория. Если указатель версии уже есть
  # (~/.carat/shards/carat/current) — путь update, иначе — полная установка.
  # Репозиторий carat не тегируется под каждый релиз — self всегда идёт по
  # HEAD master'а (head-режим): identity version+git.commit.<sha> меняется с
  # каждым пушем, update видит движение и без bump'а version.
  def self.self_command(with_examples : Bool = false, system : Bool = false) : Nil
    installer = GlobalInstaller.new(CARAT_SOURCE, with_examples, system, head: true)
    if File.exists?(Paths.current_pointer("carat"))
      installer.update
    else
      installer.install
    end
  end

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

    # Префикс режима перед install/update: `dev` — сборка без
    # --release, `only`/`shards` — только shards install/update, без сборки
    # бинарников (`shards` — синоним `only` для drop-in `shards install`).
    release = true
    only_shards = false
    if {"dev", "only", "shards"}.includes?(argv[0]?) && {"install", "update"}.includes?(argv[1]?)
      release = false if argv[0] == "dev"
      only_shards = true if {"only", "shards"}.includes?(argv[0])
      argv = argv[1..]
    end

    case command = argv[0]?
    when "install"
      rest = argv[1..]
      with_examples = !rest.delete("--with-examples").nil?
      system = !rest.delete("--system").nil?
      head = !rest.delete("head").nil?
      version = option_value(rest, "--version")
      if src = rest[0]?
        GlobalInstaller.new(src, with_examples, system, release, only_shards, head, version).install
      else
        raise Error.new("--system is only valid for global installs (carat install <src>)") if system
        ProjectInstaller.new("install", with_examples, release, only_shards).run
      end
    when "update"
      rest = argv[1..]
      with_examples = !rest.delete("--with-examples").nil?
      system = !rest.delete("--system").nil?
      head = !rest.delete("head").nil?
      if src = rest[0]?
        GlobalInstaller.new(src, with_examples, system, release, only_shards, head).update
      else
        raise Error.new("--system is only valid for global installs (carat update <src>)") if system
        ProjectInstaller.new("update", with_examples, release, only_shards).run
      end
    when "user", "system"
      name = argv[2]?
      unless argv[1]? == "remove" && name
        raise Error.new("usage: carat #{command} remove <shard>")
      end
      Remover.new(name, system: command == "system").remove
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
    when "self"
      unless {"install", "update"}.includes?(argv[1]?)
        raise Error.new("usage: carat self install|update")
      end
      rest = argv.size > 2 ? argv[2..] : [] of String
      with_examples = !rest.delete("--with-examples").nil?
      system = !rest.delete("--system").nil?
      self_command(with_examples, system)
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
    when nil       then COMMANDS + ["--help", "--version"]
    when "exec"    then typed.size == 1 ? exec_candidates : [] of String
    when "install" then typed.size == 1 ? ["head", "--with-examples", "--system", "--version"] : [] of String
    when "update"  then installed_shards + ["head", "--with-examples", "--system"]
    when "user", "system"
      case typed[1]?
      when nil      then ["remove"]
      when "remove" then installed_shards
      else               [] of String
      end
    when "dev", "only", "shards"
      case typed[1]?
      when nil       then ["install", "update"]
      when "install" then ["head", "--with-examples", "--system"]
      when "update"  then installed_shards + ["head", "--with-examples", "--system"]
      else                [] of String
      end
    when "completion" then ["install"]
    when "self"       then ["install", "update"]
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
