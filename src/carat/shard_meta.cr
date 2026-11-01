# shard.yml: имя, версия, секции binaries:/examples: (list/mapping,
# зарезервированные all:/each:), launchers: desktop-интеграции,
# assets:appicon, наличие dependencies:.

module Carat
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
    # `launchers:` бинарника — как он доставляется пользователю:
    #   terminal: true   (дефолт, фактически всегда) — бинарник в
    #                    ~/.carat/bin на PATH, обычная carat-установка
    #   menu: false      — запись в меню приложений: XDG .desktop на Linux,
    #                      ярлык в Start Menu на Windows, .app-бандл в
    #                      ~/Applications на macOS
    #   desktop: false   — ярлык на рабочем столе (в дополнение к menu, не
    #                      вместо него)
    #   args: [--no-dir] — аргументы команды запуска в нативных лаунчерах
    #                      (Exec= в .desktop, Arguments в .lnk,
    #                      CFBundleArguments в Info.plist); строка делится
    #                      по пробелам, список — по токену на элемент.
    #                      Терминальный запуск (bin на PATH) их не получает
    struct Launchers
      getter? terminal : Bool
      getter? menu : Bool
      getter? desktop : Bool
      getter args : Array(String)

      def initialize(@terminal : Bool = true, @menu : Bool = false,
                     @desktop : Bool = false,
                     @args : Array(String) = [] of String)
      end

      # Нужен ли бинарнику app-каталог/иконка/нативные лаунчеры.
      def app_integration? : Bool
        @menu || @desktop || !@terminal
      end
    end

    class BinarySpec
      getter name : String
      getter main : String
      getter prebuild : String?
      getter flags : YAML::Any?
      getter link_flags : YAML::Any?
      getter launchers : Launchers

      def initialize(@name : String, @main : String, @prebuild : String?,
                     @flags : YAML::Any?, @link_flags : YAML::Any?,
                     @launchers : Launchers = Launchers.new)
      end
    end

    # A `binaries:`/`examples:` section. Inside the mapping form two
    # reserved keys control the whole section:
    #
    #   binaries:
    #     all:                      # once per section, before any binary
    #       prebuild: rake build:native
    #     each:                     # defaults for every binary (own keys win)
    #       flags: [-DSOME=1]
    #     hello: {}
    #     tool: {main: src/tool.cr}
    #
    # `all:` runs its prebuild ONE time before the section's builds (the
    # shared native step); its flags/link_flags are the base for every
    # binary. `each:` is per-binary defaults: prebuild runs before EACH
    # binary, flags/link_flags apply to each unless the binary overrides.
    # Precedence: own > each > all. Neither key is a binary itself.
    class Section
      getter specs : Array(BinarySpec)
      getter all : BinarySpec?
      getter each : BinarySpec?

      def initialize(@specs : Array(BinarySpec), @all : BinarySpec?, @each : BinarySpec?)
      end

      def empty? : Bool
        @specs.empty?
      end
    end

    getter name : String
    getter version : String
    getter binaries : Section
    getter examples : Section
    getter? has_dependencies : Bool
    getter appicon : String?

    def initialize(@name : String, @version : String,
                   @binaries : Section, @examples : Section,
                   @has_dependencies : Bool = false, @appicon : String? = nil)
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
      # assets:appicon — иконка GUI-приложений шарда (PNG/SVG по magic bytes)
      appicon = doc["assets"]?.try(&.as_h?).try &.["appicon"]?.try &.as_s?
      # dependencies: presence decides whether a global install must run
      # `shards install` before building (the compiler resolves bare
      # requires from the project's lib/).
      deps = doc["dependencies"]?.try &.as_h?
      new(name, version, parse_section(doc, "binaries"), parse_section(doc, "examples"),
        !deps.nil? && !deps.empty?, appicon)
    end

    # A `binaries:`/`examples:` section is a list of names (main defaults
    # to src/<name>.cr) or a mapping name -> spec
    # (main/prebuild/flags/link_flags) — see Section for the reserved
    # `all:`/`each:` keys of the mapping form.
    private def self.parse_section(doc : YAML::Any, key : String) : Section
      node = doc[key]?
      specs = [] of BinarySpec
      return Section.new(specs, nil, nil) if node.nil?
      case node.raw
      when Array
        node.as_a.each do |item|
          name = item.as_s
          specs << BinarySpec.new(name, File.join("src", "#{name}.cr"), nil, nil, nil)
        end
      when Hash
        all_spec = shared_spec(node, "all")
        each_spec = shared_spec(node, "each")
        node.as_h.each do |name, spec|
          next if {"all", "each"}.includes?(name.as_s)
          e_pb, e_flags, e_link = each_spec.try(&.prebuild), each_spec.try(&.flags), each_spec.try(&.link_flags)
          a_flags, a_link = all_spec.try(&.flags), all_spec.try(&.link_flags)
          case spec.raw
          when String
            specs << BinarySpec.new(name.as_s, spec.as_s, e_pb, e_flags || a_flags, e_link || a_link)
          when Nil
            specs << BinarySpec.new(name.as_s, File.join("src", "#{name.as_s}.cr"),
              e_pb, e_flags || a_flags, e_link || a_link)
          when Hash
            main = spec["main"]?.try(&.as_s?) || File.join("src", "#{name}.cr")
            prebuild = spec["prebuild"]?.try(&.as_s?) || e_pb
            # `launchers:` — desktop-интеграция: terminal (дефолт true),
            # menu, desktop (дефолт false), args — см. Launchers
            launchers = Launchers.new
            if l = spec["launchers"]?.try(&.as_h?)
              launchers = Launchers.new(
                terminal: launcher_flag(l, "terminal", true),
                menu: launcher_flag(l, "menu", false),
                desktop: launcher_flag(l, "desktop", false),
                args: launcher_args(l))
            end
            specs << BinarySpec.new(name.as_s, main, prebuild,
              spec["flags"]? || e_flags || a_flags, spec["link_flags"]? || e_link || a_link,
              launchers)
          end
        end
      end
      Section.new(specs, all_spec, each_spec)
    end

    # launchers:-флаг: bool или дефолт (не-bool значение игнорируется).
    private def self.launcher_flag(node : Hash(YAML::Any, YAML::Any), key : String, default : Bool) : Bool
      b = node[key]?.try(&.as_bool?)
      b.nil? ? default : b
    end

    # launchers:args — строка (делится по пробелам) или список строк (по
    # токену на элемент, пробелы внутри сохраняются); прочие типы и
    # не-строчные элементы игнорируются.
    private def self.launcher_args(node : Hash(YAML::Any, YAML::Any)) : Array(String)
      raw = node["args"]?
      return [] of String unless raw
      case raw.raw
      when String then raw.as_s.split
      when Array
        raw.as_a.each_with_object([] of String) do |v, acc|
          acc << v.as_s if v.as_s?
        end
      else [] of String
      end
    end

    # The reserved `all:`/`each:` key: prebuild/flags/link_flags without
    # main (nil if absent or not a mapping).
    private def self.shared_spec(node : YAML::Any, key : String) : BinarySpec?
      raw = node.as_h[key]?
      return nil unless raw
      spec = raw.as_h?
      return nil unless spec
      BinarySpec.new(key, "",
        spec["prebuild"]?.try &.as_s?,
        spec["flags"]?, spec["link_flags"]?)
    end
  end
end
