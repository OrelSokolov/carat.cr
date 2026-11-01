# Порты и адаптеры: окружение, шелл, логгер. Ядро знает только
# абстракции; платформенные различия (POSIX/Windows) — в адаптерах.

module Carat
  # ------------------------------------------------------------------
  # Порты
  # ------------------------------------------------------------------

  module Ports
    abstract class Environment
      abstract def home : String
      abstract def path_separator : String
    end

    class PosixEnvironment < Environment
      def home : String
        ENV["HOME"]? || raise Error.new("HOME is not set")
      end

      def path_separator : String
        ":"
      end
    end

    class WindowsEnvironment < Environment
      def home : String
        if profile = ENV["USERPROFILE"]?
          profile
        elsif (drive = ENV["HOMEDRIVE"]?) && (path = ENV["HOMEPATH"]?)
          File.join(drive, path)
        else
          raise Error.new("cannot determine home directory (USERPROFILE / HOMEDRIVE+HOMEPATH)")
        end
      end

      def path_separator : String
        ";"
      end
    end

    abstract class Shell
      abstract def run(command : String, args : Array(String), cwd : String?) : Bool
      abstract def run_command(command : String, cwd : String?) : Bool
      abstract def which(command : String) : String?
    end

    class SystemShell < Shell
      # stdin наследуется: git должен иметь возможность спросить учётные
      # данные интерактивно (приватный репозиторий, https-токен, ssh-пароль).
      def run(command : String, args : Array(String), cwd : String?) : Bool
        Process.run(command, args,
          chdir: cwd,
          input: Process::Redirect::Inherit,
          output: Process::Redirect::Inherit,
          error: Process::Redirect::Inherit).success?
      end

      # A shell command line (prebuild: in binaries:) — run through the
      # platform shell so pipes/globs/env assignments work.
      def run_command(command : String, cwd : String?) : Bool
        {% if flag?(:windows) %}
          Process.run("cmd", ["/c", command], chdir: cwd,
            input: Process::Redirect::Inherit,
            output: Process::Redirect::Inherit,
            error: Process::Redirect::Inherit).success?
        {% else %}
          Process.run("sh", ["-c", command], chdir: cwd,
            input: Process::Redirect::Inherit,
            output: Process::Redirect::Inherit,
            error: Process::Redirect::Inherit).success?
        {% end %}
      end

      def which(command : String) : String?
        return command if command.includes?(File::SEPARATOR) && Carat.executable_file?(command)
        path = ENV["PATH"]?
        return nil unless path
        path.split(Carat.env.path_separator).each do |dir|
          next if dir.empty?
          candidate = File.join(dir, command)
          return candidate if Carat.executable_file?(candidate)
        end
        nil
      end
    end

    abstract class Logger
      abstract def log(line : String) : Nil
    end

    class FileLogger < Logger
      def initialize(@path : String)
      end

      def log(line : String) : Nil
        Dir.mkdir_p(File.dirname(@path))
        File.open(@path, "a") do |f|
          f.puts "#{Time.local.to_s("%Y-%m-%dT%H:%M:%S%z")} #{line}"
        end
      end
    end
  end
end
