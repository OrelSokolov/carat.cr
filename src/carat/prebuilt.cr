# Прекомпилированные бинарники из GitHub Releases: авто-детект ассета
# под текущую платформу (жёсткая конвенция + эвристика), скачивание,
# проверка (sha256-sidecar / digest, magic bytes), распаковка, укладка в
# bin_dir. Любая неудача — false, вызывающий откатывается на сборку из
# исходников, поэтому фича не может сломать установку в принципе.
#
# Релизные ассеты, а не артефакты Actions: ассеты — постоянные прямые
# ссылки без авторизации (артефакты живут 90 дней и требуют токен даже
# для публичных репо).
#
# Канонический формат (уровень 1 конвенции):
#   {name}-{version}-{os}-{arch}.tar.gz | .zip
#   os: linux | macos | windows; arch: x86_64 | arm64 | universal (macos)
# Эвристика ниже принимает синонимы (darwin≈macos, amd64≈x86_64,
# aarch64≈arm64), варианты версии (v-префикс, имя тега, отсутствие) и
# свободный порядок токенов.

module Carat
  module Prebuilt
    # Релизный ассет: имя, прямая ссылка и digest GitHub (вида
    # "sha256:...", появляется у новых ассетов; sidecar-файл
    # {asset}.sha256 проверяется тоже).
    struct Asset
      getter name : String
      getter url : String
      getter digest : String?

      def initialize(@name : String, @url : String, @digest : String? = nil)
      end
    end

    # Канонические токены платформы carat (darwin здесь — macos: имя
    # ассета пишется "macos", "darwin" принимается как синоним).
    def self.os : String
      {% if flag?(:windows) %}
        "windows"
      {% elsif flag?(:darwin) %}
        "macos"
      {% else %}
        "linux"
      {% end %}
    end

    def self.arch : String
      {% if flag?(:aarch64) %}
        "arm64"
      {% else %}
        "x86_64"
      {% end %}
    end

    # Порядок важен: macos проверяется первым — "darwin" содержит
    # подстроку "win" и иначе классифицировался бы как windows.
    OS_TOKENS = {
      "macos"   => {"darwin", "macos", "osx", "mac"},
      "windows" => {"windows", "win"},
      "linux"   => {"linux"},
    }
    ARCH_UNIVERSAL = "universal"

    # Только https://github.com — у GitLab/Gitea другой API, там всегда
    # сборка из исходников.
    GITHUB_REPO = /\Ahttps:\/\/github\.com\/([^\/]+)\/([^\/]+?)(?:\.git)?\/?\z/

    def self.github_repo(location : String) : {String, String}?
      match = location.match(GITHUB_REPO)
      match ? {match[1], match[2]} : nil
    end

    # ------------------------------------------------------------------
    # Матчинг ассета под платформу
    # ------------------------------------------------------------------

    # Классификация имени ассета: семейство ОС по синонимам, nil если
    # ОС-токена нет вовсе.
    private def self.classify_os(name : String) : String?
      down = name.downcase
      OS_TOKENS.each do |os, tokens|
        return os if tokens.any? { |t| down.includes?(t) }
      end
      nil
    end

    private def self.classify_arch(name : String) : String?
      down = name.downcase
      return ARCH_UNIVERSAL if down.includes?("universal")
      return "arm64" if down.includes?("arm64") || down.includes?("aarch64")
      if down.includes?("x86_64") || down.includes?("x86-64") ||
         down.includes?("amd64") || down.includes?("x64")
        return "x86_64"
      end
      nil
    end

    private def self.archive?(name : String) : Bool
      down = name.downcase
      return true if down.ends_with?(".exe") # голый windows-бинарник
      {".tar.gz", ".tgz", ".zip"}.any? { |ext| down.ends_with?(ext) }
    end

    # Разрешение неоднозначности внутри правила: musl-ассеты отсеиваем,
    # если есть кандидаты без libc-квалификатора (динамический musl не
    # запустится на glibc-дистрибутиве); несколько равных кандидатов —
    # не гадаем (nil → следующее правило / исходники).
    private def self.pick(candidates : Array(Asset)) : Asset?
      return nil if candidates.empty?
      # musl-ассеты отсеиваем при наличии glibc-кандидатов; остались
      # только musl — считаем правило не сработавшим (исходники)
      non_musl = candidates.reject { |a| a.name.downcase.includes?("musl") }
      return nil if non_musl.empty?
      non_musl.size == 1 ? non_musl.first : nil
    end

    # Правила по убыванию строгости; первое вернувшее единственного
    # кандидата побеждает:
    #   1. точная конвенция: {name}-{version}-... + наша os/arch
    #   2. голый {name}.exe (windows)
    #   3. свободная форма: есть имя + наша os + наш arch
    #   4. macos: universal вместо точного arch
    #   5. единственный ассет с именем и нашей os вообще без arch-токена
    #      (автор собирает только одну архитектуру)
    def self.match(assets : Array(Asset), shard_name : String, version : String,
                   os : String = self.os, arch : String = self.arch) : Asset?
      name_down = shard_name.downcase
      archives = assets.select { |a| archive?(a.name) }

      # 1. Точная конвенция (префикс с версией, разделители - или _)
      exact = archives.select do |a|
        down = a.name.downcase
        (down.starts_with?("#{name_down}-#{version.downcase}-") ||
         down.starts_with?("#{name_down}_#{version.downcase}_")) &&
          classify_os(a.name) == os && classify_arch(a.name) == arch
      end
      match = pick(exact)
      return match if match

      # 2. Голый exe: {name}.exe — безусловно наш на windows
      if os == "windows"
        bare = archives.select { |a| a.name.downcase == "#{name_down}.exe" }
        match = pick(bare)
        return match if match
      end

      # 3. Свободная форма: имя + os + arch в любом порядке/регистре
      loose = archives.select do |a|
        a.name.downcase.includes?(name_down) &&
          classify_os(a.name) == os && classify_arch(a.name) == arch
      end
      match = pick(loose)
      return match if match

      # 4. macOS: universal-ассет, если точного arch нет
      if os == "macos"
        universal = archives.select do |a|
          a.name.downcase.includes?(name_down) &&
            classify_os(a.name) == "macos" && classify_arch(a.name) == ARCH_UNIVERSAL
        end
        match = pick(universal)
        return match if match
      end

      # 5. Единственный ассет с именем и нашей os без arch-токена:
      # несколько таких — неоднозначность, исходники
      archless = archives.select do |a|
        a.name.downcase.includes?(name_down) &&
          classify_os(a.name) == os && classify_arch(a.name).nil?
      end
      archless.size == 1 ? archless.first : nil
    end

    # ------------------------------------------------------------------
    # GitHub API: ассеты релиза с тегом
    # ------------------------------------------------------------------

    # GITHUB_TOKEN / GH_TOKEN из окружения — для приватных репо и обхода
    # rate limit (без токена GitHub даёт 60 запросов/час с IP).
    private def self.token : String?
      ENV["GITHUB_TOKEN"]? || ENV["GH_TOKEN"]?
    end

    def self.release_assets(owner : String, repo : String, tag : String) : Array(Asset)?
      url = "https://api.github.com/repos/#{owner}/#{repo}/releases/tags/#{tag}"
      begin
        uri = URI.parse(url)
        client = HTTP::Client.new(uri)
        client.connect_timeout = 15.seconds
        client.read_timeout = 30.seconds
        headers = HTTP::Headers{
          "Accept"                => "application/vnd.github+json",
          "User-Agent"            => "carat/#{VERSION}",
          "X-GitHub-Api-Version"  => "2022-11-28",
        }
        headers["Authorization"] = "Bearer #{token}" if token
        response = client.get(uri.request_target, headers)
        case response.status_code
        when 200
          assets = [] of Asset
          doc = JSON.parse(response.body)
          doc["assets"]?.try(&.as_a?).try &.each do |a|
            assets << Asset.new(a["name"].as_s, a["browser_download_url"].as_s,
              a["digest"]?.try(&.as_s?))
          end
          assets
        when 404
          [] of Asset # релиза с таким тегом нет — это не ошибка
        else
          Carat.warning("WARNING: GitHub API #{response.status_code} for #{owner}/#{repo} tag #{tag}")
          nil
        end
      rescue e : Socket::Error | IO::Error | JSON::ParseException
        Carat.warning("WARNING: GitHub API unreachable (#{e.message}); building from source")
        nil
      end
    end

    # ------------------------------------------------------------------
    # Скачивание и установка
    # ------------------------------------------------------------------

    # Основной вход: найти ассет под платформу, скачать, проверить,
    # распаковать, положить все binaries: в bin_dir. true — установлено,
    # false — вызывающий собирает из исходников.
    def self.install(meta : ShardMeta, owner : String, repo : String,
                     tag : String, bin_dir : String) : Bool
      specs = meta.binaries.specs
      return false if specs.empty? # пусть обычный путь даст свою ошибку

      assets = release_assets(owner, repo, tag)
      return false if assets.nil?
      asset = match(assets, meta.name, meta.version)
      if asset.nil?
        puts "#{meta.name}: no prebuilt asset for #{os}/#{arch} in release #{tag}; building from source"
        return false
      end

      archive = File.join(Paths.tmp_dir, "prebuilt-#{Random::Secure.hex(4)}-#{asset.name}")
      unless download(asset.url, archive)
        File.delete(archive) if File.exists?(archive)
        Carat.warning("WARNING: download failed: #{asset.url}; building from source")
        return false
      end

      # sha256: sidecar-ассет {name}.sha256 или digest GitHub
      expected = sidecar_digest(assets, asset) || asset.digest.try(&.sub(/\Asha256:/, ""))
      if expected && !verify_sha256(archive, expected.strip.downcase)
        File.delete(archive)
        Carat.warning("WARNING: sha256 mismatch for #{asset.name}; building from source")
        return false
      end

      extracted = File.join(Paths.tmp_dir, "prebuilt-#{Random::Secure.hex(4)}")
      begin
        ok = extract(archive, extracted)
        unless ok && place_binaries(meta, specs, extracted, bin_dir)
          Carat.warning("WARNING: #{asset.name}: no usable #{meta.name} binaries inside; building from source")
          return false
        end
        Carat.logger.log("prebuilt #{meta.name} #{meta.version}: #{asset.name} (#{os}/#{arch}) -> #{bin_dir}")
        puts "Installed prebuilt #{meta.name} #{meta.version} from #{asset.name} (#{os}/#{arch})"
        true
      ensure
        FileUtils.rm_rf(extracted)
        File.delete(archive) if File.exists?(archive)
      end
    end

    # Скачивание с ручным следованием за редиректами (GitHub отдаёт 302
    # на подписанный URL объектов); токен — только для своих хостов
    # GitHub, чужим (S3) Authorization не отправляем.
    private def self.download(url : String, dest : String, redirects : Int32 = 5) : Bool
      return false if redirects < 0
      begin
        uri = URI.parse(url)
        client = HTTP::Client.new(uri)
        client.connect_timeout = 15.seconds
        client.read_timeout = 300.seconds
        headers = HTTP::Headers{"User-Agent" => "carat/#{VERSION}"}
        if (t = token) && uri.host.try(&.ends_with?(".github.com"))
          headers["Authorization"] = "Bearer #{t}"
        end
        response = client.get(uri.request_target, headers) do |response|
          case response.status_code
          when 200
            File.open(dest, "wb") { |f| IO.copy(response.body_io, f) }
            true
          when 301, 302, 303, 307, 308
            response.headers["Location"]?
          else
            false
          end
        end
        case response
        when Bool     then response
        when String   then redirects > 0 ? download(response, dest, redirects - 1) : false
        else               false
        end
      rescue Socket::Error | IO::Error
        false
      end
    end

    # Sidecar-контрольная сумма: ассет {name}.sha256 (или .sha256.txt),
    # содержимое вида "<hex>  <filename>" — берём первый токен.
    private def self.sidecar_digest(assets : Array(Asset), asset : Asset) : String?
      candidates = {"#{asset.name}.sha256", "#{asset.name}.sha256.txt"}
      sidecar = assets.find { |a| candidates.includes?(a.name) }
      return nil unless sidecar
      tmp = File.join(Paths.tmp_dir, "prebuilt-sha256-#{Random::Secure.hex(4)}")
      digest = nil
      if download(sidecar.url, tmp)
        digest = File.read(tmp).strip.split(/\s+/).first?
        File.delete(tmp)
      end
      digest
    end

    private def self.verify_sha256(path : String, expected : String) : Bool
      return false unless expected =~ /\A[0-9a-f]{64}\z/
      digest = Digest::SHA256.new
      File.open(path) { |f| digest.update(f) }
      digest.hexfinal == expected
    rescue File::Error
      false
    end

    # Распаковка: tar.gz/tgz — системным tar (есть везде, включая
    # Windows 10+ bsdtar), zip — stdlib Compress::Zip (без внешних
    # утилит; unzip в минималистичных Linux часто отсутствует). Zip-slip
    # исключаем: пути за пределы каталога распаковки пропускаем.
    private def self.extract(archive : String, dest : String) : Bool
      Dir.mkdir_p(dest)
      down = archive.downcase
      if down.ends_with?(".zip")
        begin
          Compress::Zip::Reader.open(archive) do |reader|
            reader.each_entry do |entry|
              next unless entry.file?
              next if entry.filename.includes?("..")
              target = File.join(dest, entry.filename)
              next unless target.starts_with?(dest)
              Dir.mkdir_p(File.dirname(target))
              File.open(target, "wb") { |f| IO.copy(entry.io, f) }
            end
          end
          true
        rescue e : Compress::Zip::Error | File::Error
          Carat.warning("WARNING: cannot extract #{File.basename(archive)} (#{e.message})")
          false
        end
      else
        unless Carat.shell.which("tar")
          Carat.warning("WARNING: tar not found in PATH — cannot extract #{File.basename(archive)}")
          return false
        end
        Carat.shell.run("tar", ["-xzf", archive, "-C", dest], nil)
      end
    end

    # Поиск бинарника из binaries: в распакованном дереве (в корне или
    # глубже — carat ищет по имени; .exe для windows-ассетов). Из
    # нескольких — самый мелкий путь (корень архива приоритетнее).
    private def self.find_extracted(dir : String, name : String) : String?
      names = {% if flag?(:windows) %} ["#{name}.exe", name] {% else %} [name] {% end %}
      names.each do |candidate|
        found = Dir.glob(File.join(dir, "**", candidate)).select { |p| File.file?(p) }
        return found.min_by? { |p| p.size } unless found.empty?
      end
      nil
    end

    # Укладка в bin_dir: magic bytes, executable-бит, копия (не rename —
    # tmp и системный каталог могут быть на разных устройствах),
    # WARNING при перезаписи + аудит-лог — как у сборки из исходников.
    private def self.place_binaries(meta : ShardMeta, specs, extracted : String, bin_dir : String) : Bool
      Dir.mkdir_p(bin_dir)
      specs.each do |spec|
        src = find_extracted(extracted, spec.name)
        return false unless src
        return false unless Artifact.binary?(src)
        target = File.join(bin_dir, spec.name)
        if File.exists?(target)
          Carat.warning("WARNING: OVERWRITING WITH NEW BINARY: #{target}")
          Carat.logger.log("overwrite #{target}: #{meta.name} #{meta.version} replaced previous binary (prebuilt)")
        end
        {% if flag?(:windows) %}
          File.delete(target) if File.exists?(target)
        {% end %}
        FileUtils.cp(src, target)
        File.chmod(target, 0o755)
      end
      true
    end
  end
end
