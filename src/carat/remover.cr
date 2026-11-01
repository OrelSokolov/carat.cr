# carat user|system remove: удаление глобальной установки, зеркальное
# установке — бинарники, примеры, GUI-приложения с лаунчерами (manifest),
# стор исходников и current-указатель.

module Carat
  # ------------------------------------------------------------------
  # Удаление глобальной установки (carat user|system remove)
  # ------------------------------------------------------------------

  # `carat user remove <name>` / `carat system remove <name>` — полное
  # удаление глобально установленного шарда, зеркальное установке:
  #  - бинарники: user → ~/.carat/bin, system → системный каталог
  #    (/usr/local/bin, %ProgramFiles%\carat\bin);
  #  - примеры: ~/.carat/examples (всегда пользовательский каталог, даже
  #    для --system-установки);
  #  - GUI-приложения: ~/.carat/apps/<name> + нативные лаунчеры из
  #    manifest (XDG .desktop / .lnk / .app-бандлы);
  #  - стор исходников ~/.carat/shards/<name>/ со всеми версиями и
  #    current-указателем.
  class Remover
    def initialize(@name : String, @system : Bool = false)
    end

    def remove : Nil
      pointer = Paths.current_pointer(@name)
      unless File.exists?(pointer)
        raise Error.new("#{@name} is not installed globally (#{pointer} not found)")
      end
      identity = File.read(pointer).strip
      store = Paths.shard_dir(@name, identity)
      bin_dir = @system ? Paths.system_bin_dir : Paths.bin_dir
      # системный каталог требует прав root/Administrator — падаем до
      # любых удалений, с той же подсказкой, что и установка
      Carat.check_writable_dir(bin_dir) if @system

      removed = [] of String
      if Dir.exists?(store)
        meta = ShardMeta.from_file(File.join(store, "shard.yml"))
        removed.concat(remove_binaries(meta, bin_dir))
        removed.concat(remove_apps(meta))
      else
        Carat.warning("WARNING: source store not found: #{store} — removing the pointer only")
      end

      FileUtils.rm_rf(File.dirname(pointer))
      Carat.logger.log("remove #{@name} #{identity}: #{removed.empty? ? "no binaries" : removed.join(", ")}")
      puts "Removed #{@name} #{identity}"
      removed.each { |path| puts "  deleted #{path}" }
    end

    private def remove_binaries(meta : ShardMeta, bin_dir : String) : Array(String)
      removed = [] of String
      other_scope = @system ? "user" : "system"
      (meta.binaries.specs + meta.examples.specs).each do |spec|
        path = File.join(bin_dir, spec.name)
        if File.exists?(path)
          File.delete(path)
          removed << path
        else
          Carat.warning("WARNING: #{path} not found — maybe installed with --system? (try: carat #{other_scope} remove #{@name})")
        end
      end
      removed
    end

    # GUI-приложения (`launchers:`): app-каталог удаляется целиком, нативные
    # лаунчеры — по списку из manifest (пути записаны при установке).
    private def remove_apps(meta : ShardMeta) : Array(String)
      removed = [] of String
      meta.binaries.specs.select(&.launchers.app_integration?).each do |spec|
        app_dir = File.join(Paths.apps_dir, spec.name)
        manifest = File.join(app_dir, "manifest")
        if File.exists?(manifest)
          File.read(manifest).each_line do |line|
            path = line.strip
            next if path.empty?
            begin
              if File.symlink?(path)
                File.delete(path)
                removed << path
              elsif Dir.exists?(path)
                FileUtils.rm_rf(path)
                removed << path
              elsif File.exists?(path)
                File.delete(path)
                removed << path
              end
            rescue e : File::Error
              Carat.warning("WARNING: could not remove #{path} (#{e.message}) — remove it manually")
            end
          end
        end
        if Dir.exists?(app_dir)
          FileUtils.rm_rf(app_dir)
          removed << app_dir
        end
      end
      removed
    end
  end
end
