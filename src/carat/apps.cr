# Дистрибуция GUI-приложений (launchers:): app-каталог с иконкой и
# manifest, нативные лаунчеры (XDG .desktop / .lnk / .app-бандл),
# контейнеры Ico/Icns с PNG-payload без конвертации.

module Carat
  # ------------------------------------------------------------------
  # Дистрибуция GUI-приложений: app-каталог + нативные лаунчеры
  # ------------------------------------------------------------------

  # `app: true` у бинарника превращает его из CLI-утилиты в desktop-приложение.
  # Вместо общего bin-каталога бинарник получает собственный app-каталог:
  #
  #   ~/.carat/apps/<name>/
  #     bin/<name>        бинарник (портабельный корень приложения)
  #     icons/<name>.png  иконка (или .svg / платформенный .ico / .icns)
  #     manifest          сгенерированные снаружи пути (задел под uninstall)
  #
  # Иконка берётся из `assets:appicon:` (любой путь в шарде), её формат
  # проверяется по magic bytes (marcel.cr) — только PNG или SVG. Конвертация
  # не требуется: .desktop принимает PNG/SVG напрямую, а .ico/.icns —
  # контейнеры, принимающие PNG-payload без перекодирования (Ico/Icns).
  #
  # На каждую платформу генерируется нативная точка входа: XDG .desktop на
  # Linux (одинаково для всех дистрибутивов — спецификация вместо uname),
  # ярлык в Start Menu на Windows, .app-бандл в ~/Applications на macOS.
  # Приложение ничего не знает про carat: свои ассеты оно ищет относительно
  # себя (portable-app конвенция), лаунчер ссылается абсолютными путями.
  module Apps
    PNG_MIME = "image/png"
    SVG_MIME = "image/svg+xml"

    # Все бинарники с desktop-интеграцией (`launchers:`) шарда: иконка,
    # при необходимости переезд бинарника с PATH в app-каталог, нативные
    # лаунчеры (menu/desktop). Вызывается после сборки (глобальная установка).
    def self.install(meta : ShardMeta, store : String, bin_dir : String) : Nil
      app_specs = meta.binaries.specs.select(&.launchers.app_integration?)
      return if app_specs.empty?
      icon = resolve_icon(meta, store)
      app_specs.each do |spec|
        install_one(meta, spec, icon, bin_dir)
      end
    end

    # Поиск и проверка appicon в корне шарда: {путь, mime} или nil.
    private def self.resolve_icon(meta : ShardMeta, store : String) : {String, String}?
      return nil unless rel = meta.appicon
      src = Path[rel].absolute? ? rel : File.join(store, rel)
      unless File.file?(src)
        raise Error.new("#{meta.name}: assets:appicon not found: #{rel}")
      end
      mime = Marcel::MimeType.for(Path[src])
      unless {PNG_MIME, SVG_MIME}.includes?(mime)
        raise Error.new("#{meta.name}: assets:appicon must be PNG or SVG, got #{mime} (#{rel})")
      end
      {src, mime}
    end

    private def self.install_one(meta : ShardMeta, spec : ShardMeta::BinarySpec,
                                 icon : {String, String}?, bin_dir : String) : Nil
      name = spec.name
      src_bin = File.join(bin_dir, name)
      raise Error.new("#{meta.name}: app binary #{name} not found in #{bin_dir}") unless File.exists?(src_bin)
      l = spec.launchers
      unless icon
        if l.menu? || l.desktop?
          Carat.warning("WARNING: #{meta.name}: #{name} has launchers: but shard.yml has no assets:appicon — launcher without icon")
        end
      end

      app_dir = File.join(Paths.apps_dir, name)
      FileUtils.rm_rf(app_dir) if Dir.exists?(app_dir)
      Dir.mkdir_p(app_dir)
      icon_file = icon.try { |src, mime| install_icon(name, src, mime, app_dir) }

      # terminal: false — бинарник уходит с PATH в собственный app-каталог
      app_bin = src_bin
      unless l.terminal?
        Dir.mkdir_p(File.join(app_dir, "bin"))
        app_bin = File.join(app_dir, "bin", name)
        move_binary(src_bin, app_bin)
      end

      created = deploy_launchers(name, app_bin, icon_file, app_dir, l)
      File.write(File.join(app_dir, "manifest"), created.join("\n"))
      Carat.logger.log("app #{meta.name} #{meta.version}: #{name} -> #{(created + [app_bin]).join(", ")}")
      puts "App #{name} -> #{(created.empty? ? [app_bin] : created).join(", ")}"
    end

    # Копирование/конвертация иконки в app-каталог; nil — иконка невозможна
    # (SVG на Windows/macOS без растеризатора).
    private def self.install_icon(name : String, src : String, mime : String,
                                  app_dir : String) : String?
      icons = File.join(app_dir, "icons")
      Dir.mkdir_p(icons)
      png = mime == PNG_MIME ? File.read(src).to_slice : Bytes.empty
      {% if flag?(:windows) %}
        if mime == SVG_MIME
          Carat.warning("appicon #{name}: SVG needs no conversion on Linux, but .ico requires a rasterizer — shortcut without icon")
          return nil
        end
        File.write(File.join(icons, "#{name}.ico"), Ico.wrap_png(png))
        "#{name}.ico"
      {% elsif flag?(:darwin) %}
        if mime == SVG_MIME
          Carat.warning("appicon #{name}: SVG cannot become .icns without a rasterizer — bundle without icon")
          return nil
        end
        File.write(File.join(icons, "#{name}.icns"), Icns.wrap_png(png))
        "#{name}.icns"
      {% else %}
        ext = mime == SVG_MIME ? "svg" : "png"
        FileUtils.cp(src, File.join(icons, "#{name}.#{ext}"))
        "#{name}.#{ext}"
      {% end %}
    end

    # Размеры из IHDR (PNG-заголовок) — для Ico/Icns без декодирования.
    def self.png_dimensions(png : Bytes) : {Int32, Int32}
      unless png.size >= 24 && png[0, 8] == Bytes[137, 80, 78, 71, 13, 10, 26, 10]
        raise Error.new("appicon: not a valid PNG (IHDR too short)")
      end
      {IO::ByteFormat::BigEndian.decode(Int32, png[16, 4]),
       IO::ByteFormat::BigEndian.decode(Int32, png[20, 4])}
    end

    {% if flag?(:windows) %}
      # Ярлыки через WScript.Shell (уровень пользователя — администратор не
      # нужен): menu → Start Menu\Programs, desktop → Desktop. Desktop
      # резолвится в самом PowerShell (локализованные системы, OneDrive),
      # для manifest/logs предполагается ~\Desktop.
      private def self.deploy_launchers(name : String, app_bin : String,
                                        icon_file : String?, app_dir : String,
                                        l : ShardMeta::Launchers) : Array(String)
        menu = ENV["APPDATA"]? || File.join(Carat.env.home, "AppData", "Roaming")
        icon = icon_file.try { |f| File.join(app_dir, "icons", f) }
        stmts = ""
        created = [] of String
        if l.menu?
          lnk = File.join(menu, "Microsoft", "Windows", "Start Menu", "Programs", "#{name}.lnk")
          stmts += shortcut_ps(ps_quote(lnk), ps_quote(app_bin), icon)
          created << lnk
        end
        if l.desktop?
          desktop = File.join(Carat.env.home, "Desktop", "#{name}.lnk")
          # путь собирается в PS: Join-Path (GetFolderPath 'Desktop') name.lnk
          stmts += shortcut_ps(
            "(Join-Path ([Environment]::GetFolderPath('Desktop')) '#{name}.lnk')",
            ps_quote(app_bin), icon)
          created << desktop
        end
        unless Carat.shell.run("powershell", ["-NoProfile", "-Command", stmts], nil)
          Carat.warning("WARNING: could not create shortcuts for #{name} (#{created.join(", ")}) — create them manually")
        end
        created
      end

      # PS-фрагмент одного ярлыка: path — уже PS-строка или выражение.
      # Строки вместо heredoc: heredoc внутри макро-ветки компилятор не
      # разворачивает (unexpected token <<).
      private def self.shortcut_ps(path : String, target : String, icon : String?) : String
        icon_stmt = icon.try { |i| "$s.IconLocation = '#{ps_quote(i)},0';" } || ""
        [
          "$s = (New-Object -ComObject WScript.Shell).CreateShortcut(#{path});",
          "$s.TargetPath = '#{target}';",
          icon_stmt,
          "$s.Save();",
          "Write-Output $s.FullName;",
        ].reject(&.empty?).join("\n")
      end

      private def self.ps_quote(s : String) : String
        s.gsub("/", "\\").gsub('\'', "''")
      end
    {% elsif flag?(:darwin) %}
      # menu → .app-бандл в ~/Applications (Launchpad = меню macOS);
      # desktop → симлинк на бандл на рабочем столе (или бандл прямо на
      # столе, если menu выключен). Бинарник в бандле — копия: PATH-оригинал
      # (terminal: true) остаётся на месте.
      private def self.deploy_launchers(name : String, app_bin : String,
                                        icon_file : String?, app_dir : String,
                                        l : ShardMeta::Launchers) : Array(String)
        display = name.capitalize
        home = Carat.env.home
        created = [] of String
        if l.menu? || !l.desktop?
          bundle = make_bundle(name, display, app_bin, icon_file, app_dir,
            File.join(home, "Applications"))
          created << bundle
          if l.desktop?
            link = File.join(home, "Desktop", "#{display}.app")
            File.delete(link) if File.exists?(link) || File.symlink?(link)
            File.symlink(bundle, link)
            created << link
          end
        else # только desktop: бандл прямо на рабочем столе
          created << make_bundle(name, display, app_bin, icon_file, app_dir,
            File.join(home, "Desktop"))
        end
        created
      end

      # .app-бандл: бинарник в Contents/MacOS, icns в Contents/Resources,
      # Info.plist связывает их.
      private def self.make_bundle(name : String, display : String, app_bin : String,
                                   icon_file : String?, app_dir : String,
                                   parent : String) : String
        bundle = File.join(parent, "#{display}.app")
        FileUtils.rm_rf(bundle) if Dir.exists?(bundle)
        macos = File.join(bundle, "Contents", "MacOS")
        resources = File.join(bundle, "Contents", "Resources")
        Dir.mkdir_p(macos)
        Dir.mkdir_p(resources)
        FileUtils.cp(app_bin, File.join(macos, name))
        if icon_file
          FileUtils.cp(File.join(app_dir, "icons", icon_file), File.join(resources, "app.icns"))
        end
        # строки вместо heredoc — см. shortcut_ps
        plist = [
          %(<?xml version="1.0" encoding="UTF-8"?>),
          %(<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">),
          %(<plist version="1.0">),
          "<dict>",
          "<key>CFBundleName</key><string>#{display}</string>",
          "<key>CFBundleExecutable</key><string>#{name}</string>",
          # иконки может не быть — ключ CFBundleIconFile только при ней
          icon_file ? "<key>CFBundleIconFile</key><string>app</string>" : "",
          "<key>CFBundleIdentifier</key><string>carat.#{name}</string>",
          "<key>CFBundlePackageType</key><string>APPL</string>",
          "</dict>",
          "</plist>",
        ].reject(&.empty?).join("\n")
        File.write(File.join(bundle, "Contents", "Info.plist"), plist)
        bundle
      end
    {% else %}
      # XDG .desktop — единообразно на всех дистрибутивах Linux/BSD:
      # спецификация вместо определения дистрибутива по uname. menu →
      # ~/.local/share/applications (меню приложений DE), desktop → каталог
      # рабочего стола (XDG_DESKTOP_DIR, дефолт ~/Desktop).
      private def self.deploy_launchers(name : String, app_bin : String,
                                        icon_file : String?, app_dir : String,
                                        l : ShardMeta::Launchers) : Array(String)
        entry = String.build do |s|
          s << "[Desktop Entry]\n"
          s << "Type=Application\n"
          s << "Name=#{name}\n"
          s << "Exec=\"#{app_bin}\"\n"
          s << "Icon=#{File.join(app_dir, "icons", icon_file)}\n" if icon_file
          s << "Terminal=false\n"
          s << "Categories=Utility;\n"
        end
        created = [] of String
        if l.menu?
          xdg = ENV["XDG_DATA_HOME"]?
          data_home = xdg && xdg.starts_with?('/') ? xdg : File.join(Carat.env.home, ".local", "share")
          applications = File.join(data_home, "applications")
          Dir.mkdir_p(applications)
          desktop_file = File.join(applications, "#{name}.desktop")
          File.write(desktop_file, entry)
          created << desktop_file
        end
        if l.desktop?
          target = File.join(desktop_dir, "#{name}.desktop")
          Dir.mkdir_p(desktop_dir)
          File.write(target, entry)
          created << target
        end
        created
      end

      # Каталог рабочего стола: XDG_DESKTOP_DIR из user-dirs.dirs
      # (локализованные системы), дефолт ~/Desktop.
      private def self.desktop_dir : String
        dirs = File.join(Carat.env.home, ".config", "user-dirs.dirs")
        if File.file?(dirs)
          if m = File.read(dirs).match(/XDG_DESKTOP_DIR="([^"]+)"/)
            path = m[1].gsub("$HOME", Carat.env.home)
            return path if path.starts_with?('/')
          end
        end
        File.join(Carat.env.home, "Desktop")
      end
    {% end %}

    # Переезд бинарника; rename может упасть через fs-границу (--system:
    # /usr/local/bin) — тогда копия + удаление.
    private def self.move_binary(src : String, dst : String) : Nil
      begin
        File.rename(src, dst)
      rescue File::Error
        FileUtils.cp(src, dst)
        File.delete(src)
      end
    end
  end

  # ICO-контейнер с PNG-payload: Windows Vista+ принимает вложенный PNG без
  # перекодирования — «конвертация» иконки сводится к 22 байтам заголовка.
  module Ico
    def self.wrap_png(png : Bytes) : Bytes
      width, height = Apps.png_dimensions(png)
      out = IO::Memory.new(22 + png.size)
      out.write Bytes[0, 0] # reserved (LE)
      out.write Bytes[1, 0] # type: 1 = icon (LE)
      out.write Bytes[1, 0] # image count (LE)
      out.write_byte (width >= 256 ? 0 : width).to_u8!
      out.write_byte (height >= 256 ? 0 : height).to_u8!
      out.write_byte 0       # palette size
      out.write_byte 0       # reserved
      out.write Bytes[1, 0]  # color planes (LE)
      out.write Bytes[32, 0] # bits per pixel: 32 (LE)
      out.write_bytes png.size.to_u32, IO::ByteFormat::LittleEndian
      out.write_bytes 22_u32, IO::ByteFormat::LittleEndian
      out.write png
      out.to_slice
    end
  end

  # ICNS-контейнер с PNG-payload: современные секции (ic07..ic10) — это PNG,
  # растеризация не нужна. Секция выбирается по фактической ширине IHDR.
  module Icns
    SECTIONS = {1024 => "ic10", 512 => "ic09", 256 => "ic08", 128 => "ic07"}

    def self.wrap_png(png : Bytes) : Bytes
      width, _ = Apps.png_dimensions(png)
      type = SECTIONS.keys.sort.reverse.find { |size| width >= size } || 128
      out = IO::Memory.new(16 + png.size)
      out.write "icns".to_slice
      out.write_bytes (16 + png.size).to_u32, IO::ByteFormat::BigEndian
      out.write SECTIONS[type].to_slice
      out.write_bytes (8 + png.size).to_u32, IO::ByteFormat::BigEndian
      out.write png
      out.to_slice
    end
  end
end
