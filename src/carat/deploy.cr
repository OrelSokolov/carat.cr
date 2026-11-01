# Деплой демонов на linux-сервер (carat deploy): сборка локально, scp,
# capistrano-релизы (releases/<identity>/ + current-симлинк), systemd-юнит
# на current/<name>, атомарное переключение + restart с проверкой.
# Серверу нужны только ssh и systemd — тулчейна на сервере не требуется.

module Carat
  # ------------------------------------------------------------------
  # Деплой: carat deploy | carat deploy rollback | carat logs | carat status
  # ------------------------------------------------------------------

  # Ультрабыстрый деплой самодостаточного бинарника-демона: одна команда,
  # ноль конфигурации на сервере. Контракт — `daemon:` у бинарника в
  # shard.yml (свойство бинарника, как launchers:), окружение — deploy.yml
  # рядом с shard.yml (только для именованных серверов):
  #
  #   servers:                     # deploy.yml
  #     production:
  #       host: 203.0.113.10
  #       user: deploy             # default root
  #       port: 22
  #       path: /opt/myapp         # default /opt/<shard-name>
  #
  # Раскладка на сервере — capistrano: releases/<identity>/ со всеми
  # бинарниками шарда + current-симлинк; systemd-юнит ссылается на
  # current/<name>, обновление = атомарный переключатель (ln + mv -T) +
  # systemctl restart. Откат — carat deploy rollback: current на предыдущий
  # релиз + restart. Права: root или passwordless sudo (sudo -n), проверка
  # ДО локальной сборки — как check_writable_dir у --system.
  class Deploy
    KEEP_RELEASES = 5
    SYSTEMD       = "/etc/systemd/system"

    # Цель деплоя: именованный сервер из deploy.yml или сырой user@host[:port].
    class Target
      getter name : String
      getter host : String
      getter user : String
      getter port : Int32

      def initialize(@name : String, @host : String, @user : String = "root",
                     @port : Int32 = 22)
      end
    end

    getter meta : ShardMeta
    getter target : Target
    getter deploy_path : String
    @project : String
    @clone : String?
    @fixed_identity : String?

    # deploy.yml каталога проекта: имя -> {target, path?}.
    def self.servers(dir : String = Dir.current) : Hash(String, {Target, String?})
      path = File.join(dir, "deploy.yml")
      return {} of String => {Target, String?} unless File.file?(path)
      doc = YAML.parse(File.read(path)) rescue raise Error.new("invalid deploy.yml: #{path}")
      node = doc["servers"]?
      raise Error.new("deploy.yml has no servers: section: #{path}") if node.nil?
      servers = {} of String => {Target, String?}
      node.as_h.each do |name, spec|
        h = spec.as_h? || raise Error.new("deploy.yml: server #{name} must be a mapping")
        host = h["host"]?.try(&.as_s?) ||
               raise Error.new("deploy.yml: server #{name} has no host")
        servers[name.as_s] = {
          Target.new(name.as_s, host,
            h["user"]?.try(&.as_s?) || "root",
            h["port"]?.try(&.as_i?) || 22),
          h["path"]?.try(&.as_s?),
        }
      end
      servers
    end

    # src — что деплоим: nil — шард из текущего каталога; локальный каталог;
    # owner/repo | git URL — резолв и shallow-клон как у install (старший
    # semver-тег, иначе HEAD дефолтной ветки), клон вычищается после деплоя.
    # raw — цель: имя сервера из deploy.yml проекта, user@host[:port] или
    # nil (тогда — единственный определённый сервер).
    def initialize(src : String? = nil, raw : String? = nil)
      @project, @clone, @fixed_identity = prepare(src)
      @meta = ShardMeta.from_file(File.join(@project, "shard.yml"))
      @deploy_path, @target = resolve(raw)
    end

    def deploy : Nil
      ds = daemons
      if ds.empty?
        raise Error.new("#{meta.name}: no binaries with daemon: in shard.yml — nothing to deploy")
      end
      identity = release_identity
      puts "Deploying #{meta.name} #{identity} -> #{ssh_dest}:#{deploy_path}"
      ensure_access

      staging = File.join(Paths.tmp_dir, "deploy-#{Random::Secure.hex(4)}")
      FileUtils.rm_rf(staging) if Dir.exists?(staging)
      Dir.mkdir_p(staging)
      begin
        Carat.install_dependencies(meta, @project)
        built = Carat.build_binaries(meta, @project, staging, warn_overwrite: false)
        built.each { |bin| ensure_linux_elf(bin) }
        activate(staging, built, ds, identity)
      ensure
        FileUtils.rm_rf(staging)
        if clone = @clone
          FileUtils.rm_rf(clone)
        end
      end
      Carat.logger.log("deploy #{meta.name} #{identity} -> #{ssh_dest}:#{deploy_path}")
    end

    # current на предыдущий релиз + restart: главный capistrano-ингредиент.
    def rollback : Nil
      ds = daemons
      raise Error.new("#{meta.name}: no binaries with daemon: in shard.yml") if ds.empty?
      list = release_list
      raise Error.new("no releases on #{ssh_dest}:#{deploy_path} — nothing to roll back") if list.empty?
      current = current_release.try { |l| File.basename(l) }
      # Свежайшие первыми: current обычно list[0]; откат — на следующий по
      # свежести. current не найден (симлинк вручную?) — считаем свежайший.
      idx = current ? list.index(current) : nil
      idx = 0 if idx.nil?
      if idx == list.size - 1
        raise Error.new("already at the oldest release: #{list[idx]}")
      end
      prev = list[idx + 1]
      puts "Rolling back #{meta.name}: #{current || list.first} -> #{prev}"
      link = File.join(deploy_path, "current")
      release = File.join(deploy_path, "releases", prev)
      units = ds.map { |s| sh(s.name) }.join(" ")
      script = "rm -f #{sh(link + ".tmp")} && ln -s #{sh(release)} #{sh(link + ".tmp")} && " \
               "mv -T #{sh(link + ".tmp")} #{sh(link)} && systemctl restart #{units}"
      unless remote(priv(script))
        raise Error.new("rollback failed on #{target.host} — see the output above")
      end
      verify_units
      Carat.logger.log("deploy rollback #{meta.name} -> #{prev} on #{ssh_dest}")
      puts "Rolled back #{meta.name} to #{prev}"
    end

    # Хвост журнала каждого задеплоенного сервиса (journalctl).
    def logs : Nil
      ds = daemons
      raise Error.new("#{meta.name}: no binaries with daemon: in shard.yml") if ds.empty?
      ds.each do |spec|
        puts "---- #{spec.name} (#{ssh_dest}:#{deploy_path}) ----"
        remote(priv("journalctl -u #{sh(spec.name)} -n 200 --no-pager"))
      end
    end

    # systemctl status задеплоенных сервисов + текущий релиз.
    def status : Nil
      puts "#{meta.name} on #{ssh_dest}:#{deploy_path} -> current = #{current_release || "(not deployed)"}"
      ds = daemons
      return if ds.empty?
      units = ds.map { |s| sh(s.name) }.join(" ")
      remote(priv("systemctl status --no-pager #{units}"))
    end

    # ------------------------------------------------------------------
    # Внутреннее
    # ------------------------------------------------------------------

    private def daemons : Array(ShardMeta::BinarySpec)
      meta.binaries.specs.select(&.daemon)
    end

    # Каталог проекта для деплоя. Возвращает {project, временный клон,
    # предвычисленный identity}: клон — только для git-источника (вычищается
    # после деплоя), identity для клона берётся из резолва (тег/коммит), для
    # локальных каталогов — считается на месте.
    private def prepare(src : String?) : {String, String?, String?}
      return {Dir.current, nil, nil} if src.nil?
      source = Carat.resolve_source(src)
      case source.kind
      in Source::Kind::Local
        {source.location, nil, nil}
      in Source::Kind::Git
        Paths.ensure_global_dirs
        meta, staged, identity = Carat.clone_git(source, Carat.latest_tag(source.location))
        {staged, staged, identity}
      end
    end

    private def resolve(raw : String?) : {String, Target}
      servers = Deploy.servers(@project)
      if raw.nil?
        unless servers.size == 1
          hint = servers.empty? ? "" : " (#{servers.keys.join(", ")})"
          raise Error.new("specify a target: carat deploy user@host[:port] or a server name#{hint}")
        end
        target, path = servers.first[1]
        return {path || "/opt/#{meta.name}", target}
      end
      if pair = servers[raw]?
        return {pair[1] || "/opt/#{meta.name}", pair[0]}
      end
      if raw.includes?('@')
        user, _, host = raw.partition('@')
        port = 22
        if host.includes?(':')
          host, _, p = host.partition(':')
          port = p.to_i? || raise Error.new("invalid port in target: #{raw}")
        end
        return {"/opt/#{meta.name}", Target.new(raw, host, user, port)}
      end
      known = servers.empty? ? " (no servers: in deploy.yml)" : " (known: #{servers.keys.join(", ")})"
      raise Error.new("unknown server: #{raw}#{known}")
    end

    # Релиз = identity проекта: git-источник — identity резолва (тег →
    # version, HEAD → version+commit); локальный каталог — version + коммит
    # рабочего дерева (нотация shard.lock); не-git каталог — просто version.
    private def release_identity : String
      return @fixed_identity.not_nil! if @fixed_identity
      sha = Carat.git(["rev-parse", "HEAD"], @project)
      sha ? "#{meta.version}+git.commit.#{sha.strip[0, 10]}" : meta.version
    end

    # Доступность и права — ДО локальной сборки (как check_writable_dir у
    # --system): ssh должен проходить, root/passwordless-sudo — писать в
    # deploy_path.
    private def ensure_access : Nil
      unless remote("true")
        raise Error.new("ssh failed: #{ssh_dest} — check connectivity and auth (keys/agent)")
      end
      probe = File.join(deploy_path, ".carat-deploy-probe")
      unless remote(priv("mkdir -p #{sh(deploy_path)} && touch #{sh(probe)} && rm #{sh(probe)}"))
        raise Error.new("no write access to #{deploy_path} on #{target.host} as #{target.user}" \
                        " — deploy needs root: connect as root or configure passwordless sudo")
      end
    end

    # Единственный ELF принимается: кросс-компиляции нет, деплой собирается
    # на машине той же платформы, что и сервер.
    private def ensure_linux_elf(path : String) : Nil
      magic = Bytes.new(4)
      File.open(path) { |f| f.read(magic) }
      return if magic == Bytes[0x7F, 69, 76, 70]
      raise Error.new("#{File.basename(path)} is not a Linux ELF binary — carat deploy builds" \
                      " on the machine it runs on: run it from a Linux host of the server's arch")
    end

    # Приём локальной сборки: scp в /tmp (не-root в /opt писать не может),
    # затем один удалённый скрипт: mv бинарников в релиз, юниты (только
    # изменившиеся), атомарный переключатель current, enable + restart.
    private def activate(local : String, built : Array(String),
                         ds : Array(ShardMeta::BinarySpec), identity : String) : Nil
      release = File.join(deploy_path, "releases", identity)
      remote_tmp = "/tmp/carat-#{meta.name}-#{Random::Secure.hex(4)}"

      units = ds.map { |spec| {spec, unit_content(spec)} }
      changed = units.select { |spec, content| !remote_unit_current?(spec, content) }
      units.each do |spec, content|
        File.write(File.join(local, "#{spec.name}.service"), content)
      end

      files = built.map { |b| File.basename(b) } + units.map { |spec, _| "#{spec.name}.service" }
      # Staging — от имени логин-юзера (как у capistrano: загрузка всегда в
      # user-writable место; /tmp таковым является без sudo). sudo для mkdir
      # сделал бы каталог root-овым и scp от логин-юзера упал бы с
      # Permission denied; sudo остаётся только на активацию (mv в deploy_path,
      # юниты, systemctl).
      unless remote("mkdir -p #{sh(remote_tmp)}")
        raise Error.new("could not create staging dir #{remote_tmp} on #{target.host}")
      end
      scp = ["-P", target.port.to_s] + files.map { |f| File.join(local, f) } + ["#{ssh_dest}:#{remote_tmp}"]
      unless Carat.shell.run("scp", scp, nil)
        raise Error.new("scp failed: could not upload to #{ssh_dest}:#{remote_tmp}")
      end

      names = units.map { |spec, _| sh(spec.name) }.join(" ")
      script = String.build do |s|
        s << "set -e\n"
        s << "mkdir -p #{sh(release)}\n"
        built.each do |b|
          n = File.basename(b)
          s << "mv #{sh(File.join(remote_tmp, n))} #{sh(File.join(release, n))}" \
             << " && chmod +x #{sh(File.join(release, n))}\n"
        end
        changed.each do |spec, _|
          s << "mv #{sh(File.join(remote_tmp, "#{spec.name}.service"))}" \
             << " #{sh(File.join(SYSTEMD, "#{spec.name}.service"))}\n"
        end
        s << "systemctl daemon-reload\n" unless changed.empty?
        link = File.join(deploy_path, "current")
        s << "rm -f #{sh(link + ".tmp")} && ln -s #{sh(release)} #{sh(link + ".tmp")}" \
           << " && mv -T #{sh(link + ".tmp")} #{sh(link)}\n"
        s << "systemctl enable #{names}\n"
        s << "systemctl restart #{names}\n"
        s << "rm -rf #{sh(remote_tmp)}\n"
      end
      unless remote(priv(script))
        raise Error.new("activation failed on #{target.host} — see the output above")
      end

      verify_units
      cleanup_releases
      puts "Deployed #{meta.name} #{identity}: current -> #{release}" \
           " (#{units.map { |spec, _| "#{spec.name}.service" }.join(", ")})"
    end

    # Юнит на current/<name>: ExecStart через симлинк, чтобы обновление не
    # трогало unit-файл — рестарт подхватывает новый релиз сам.
    private def unit_content(spec : ShardMeta::BinarySpec) : String
      d = spec.daemon.not_nil!
      args = d.args.empty? ? "" : " " + d.args.map { |a| sh(a) }.join(" ")
      <<-UNIT
        [Unit]
        Description=#{d.description || spec.name}
        After=network.target

        [Service]
        ExecStart=#{deploy_path}/current/#{spec.name}#{args}
        WorkingDirectory=#{deploy_path}/current
        Restart=#{d.restart}

        [Install]
        WantedBy=multi-user.target
        UNIT
    end

    private def remote_unit_current?(spec : ShardMeta::BinarySpec, content : String) : Bool
      existing = remote_capture(priv("cat #{sh(File.join(SYSTEMD, "#{spec.name}.service"))} 2>/dev/null"))
      existing == content
    end

    # Деплой не вслепую: is-active после рестарта, при падении — хвост
    # журнала прямо в вывод и ошибка с подсказкой про rollback.
    private def verify_units : Nil
      sleep 1.seconds
      daemons.each do |spec|
        next if remote(priv("systemctl is-active --quiet #{sh(spec.name)}"))
        remote(priv("journalctl -u #{sh(spec.name)} -n 30 --no-pager"))
        raise Error.new("#{spec.name} failed to start on #{target.host} (journal above)" \
                        " — roll back with: carat deploy rollback")
      end
    end

    # Capistrano-гигиена: держим последние KEEP_RELEASES релизов по времени
    # (текущий — всегда свежейший, в диапазоне остаётся предыдущий для
    # rollback).
    private def cleanup_releases : Nil
      releases = File.join(deploy_path, "releases")
      unless remote(priv("cd #{sh(releases)} && ls -1t | tail -n +#{KEEP_RELEASES + 1} | xargs -r rm -rf"))
        Carat.warning("WARNING: could not clean up old releases in #{releases} on #{target.host}")
      end
    end

    # Релизы на сервере, свежайшие первыми (mtime): порядок деплоев, а не
    # лексикография identity (git-sha в ней не отражает очерёдность).
    private def release_list : Array(String)
      releases = File.join(deploy_path, "releases")
      remote_capture(priv("ls -1t #{sh(releases)}"))
        .try(&.lines.map(&.strip).reject(&.empty?)) || [] of String
    end

    private def current_release : String?
      remote_capture(priv("readlink #{sh(File.join(deploy_path, "current"))}")).try(&.strip)
    end

    # ------------------------------------------------------------------
    # ssh/scp: аутентификация делегирована ssh (ключи, agent, ProxyJump —
    # всё работает бесплатно), вывод наследуется.
    # ------------------------------------------------------------------

    private def ssh_dest : String
      "#{target.user}@#{target.host}"
    end

    private def remote(cmd : String) : Bool
      Carat.shell.run("ssh", ["-p", target.port.to_s, ssh_dest, cmd], nil)
    end

    private def remote_capture(cmd : String) : String?
      buf = IO::Memory.new
      result = Process.run("ssh", ["-p", target.port.to_s, ssh_dest, cmd],
        output: buf, error: Process::Redirect::Inherit)
      result.success? ? buf.to_s : nil
    end

    # root исполняет сам; не-root — через passwordless sudo (sudo -n: без
    # пароля, иначе деплой падает с понятной ошибкой вместо зависания).
    private def priv(cmd : String) : String
      target.user == "root" ? cmd : "sudo -n sh -c #{sh(cmd)}"
    end

    # sh-квотинг одной строки: '…' с escape встроенной кавычки.
    private def sh(s : String) : String
      "'#{s.gsub('\'', "'\\''")}'"
    end
  end
end
