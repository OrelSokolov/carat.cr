# Проектная установка: делегирует `shards install|update`, собирает
# binaries: в ./.carat/bin (binstubs для carat exec).

module Carat
  # ------------------------------------------------------------------
  # Проектная установка (аналог bundle install + binstubs)
  # ------------------------------------------------------------------

  class ProjectInstaller
    # release=false — dev-сборка (без --release); only_shards=true — только
    # `shards install`/`shards update`, без сборки бинарников.
    def initialize(@shards_command : String = "install", @with_examples : Bool = false,
                   @release : Bool = true, @only_shards : Bool = false)
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
      if @only_shards
        puts "Shards #{@shards_command} done"
        Carat.logger.log("project #{@shards_command} #{meta.name} #{meta.version} -> only shards, no build")
        return
      end
      if meta.binaries.empty?
        # a library project (no binaries) is a legitimate carat install
        puts "No binaries entry in shard.yml, skipping"
        Carat.logger.log("project #{@shards_command} #{meta.name} #{meta.version} -> no binaries, nothing to build")
        return
      end
      bin_dir = Paths.project_bin
      built = Carat.build_binaries(meta, Dir.current, bin_dir, @release, warn_overwrite: false)
      Carat.logger.log("project #{@shards_command} #{meta.name} #{meta.version} -> #{bin_dir} (#{built.map { |p| File.basename(p) }.join(", ")})")
      puts "Installed #{meta.name} #{meta.version} -> #{bin_dir}"
      return unless @with_examples
      if meta.examples.empty?
        puts "#{meta.name}: no examples: entry in shard.yml, skipping examples"
        return
      end
      examples_dir = Paths.project_examples
      built = Carat.build_examples(meta, Dir.current, examples_dir, @release, warn_overwrite: false)
      Carat.logger.log("project examples #{@shards_command} #{meta.name} #{meta.version} -> #{examples_dir} (#{built.map { |p| File.basename(p) }.join(", ")})")
      puts "Examples -> #{examples_dir}"
    end
  end
end
