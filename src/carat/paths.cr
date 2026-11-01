# Все пути раскладки carat: ~/.carat/bin, стор шардов, приложения,
# логи, staging; системный каталог установки --system.

module Carat
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

    # Куда кладёт бинарники --system: /usr/local/bin на Unix (каталог для
    # вручную установленного софта, на PATH по умолчанию; /bin на macOS
    # read-only из-за SIP, на Linux — территория пакетного менеджера) и
    # %ProgramFiles%\carat\bin на Windows.
    def self.system_bin_dir : String
      {% if flag?(:windows) %}
        program_files = ENV["ProgramFiles"]? || ENV["ProgramW6432"]? || "C:\\Program Files"
        File.join(program_files, "carat", "bin")
      {% else %}
        "/usr/local/bin"
      {% end %}
    end

    def self.examples_dir : String
      File.join(carat_home, "examples")
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

    # Каталоги GUI-приложений (`app: true`): по одному на бинарник.
    def self.apps_dir : String
      File.join(carat_home, "apps")
    end

    def self.project_bin : String
      File.join(Dir.current, ".carat", "bin")
    end

    def self.project_examples : String
      File.join(Dir.current, ".carat", "examples")
    end

    def self.ensure_global_dirs : Nil
      [bin_dir, shards_dir, logs_dir, tmp_dir, apps_dir].each { |d| Dir.mkdir_p(d) }
    end
  end
end
