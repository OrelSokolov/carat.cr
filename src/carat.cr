# carat — глобальный установщик бинарников для Crystal-шардов.
#
# `carat install owner/repo` тащит шард с GitHub, собирает `binaries:`
# через `crystal build --release` и кладёт самодостаточные бинарники в ~/.carat/bin.
#
# Архитектура: порты и адаптеры (по образцу Egui::SystemPorts) — ядро не знает
# про ОС, платформенные различия живут в адаптерах, выбор — compile-time флаги.

require "yaml"
require "file_utils"
require "colorize"
require "json"
require "digest"
require "uri"
require "http/client"
require "compress/zip"
require "sysinfo"
require "marcel_cr"

require "./carat/*"

module Carat
  VERSION = "0.15.0"

  class Error < Exception
  end

  @@env : Ports::Environment? = nil
  @@shell : Ports::Shell? = nil
  @@logger : Ports::Logger? = nil

  def self.executable_file?(path : String) : Bool
    # любой execute-бит (0o111)
    !!File.info?(path).try { |info| (info.permissions.value & 0o111) != 0 }
  end

  # Цвета только для интерактивного вывода: NO_COLOR и редирект в пайп
  # отключают escape-коды (иначе они засоряют логи и вывод в файлах).
  def self.colors? : Bool
    !ENV["NO_COLOR"]? && STDOUT.tty? && STDERR.tty?
  end

  def self.paint(line : String, color : Colorize::Color) : String
    colors? ? line.colorize(color).to_s : line
  end

  def self.warning(line : String) : Nil
    puts paint(line, :yellow)
  end

  # Захваченный stdout git-команды (в отличие от Shell#run, который всё
  # наследует) — для резолва тегов/коммитов. stderr наследуется, чтобы
  # причину ошибки (auth, сеть) пользователь видел сразу.
  def self.git(args : Array(String), cwd : String? = nil) : String?
    buf = IO::Memory.new
    result = Process.run("git", args, chdir: cwd, output: buf,
      error: Process::Redirect::Inherit)
    result.success? ? buf.to_s : nil
  end

  def self.env : Ports::Environment
    @@env ||= {% if flag?(:windows) %}Ports::WindowsEnvironment.new{% else %}Ports::PosixEnvironment.new{% end %}
  end

  def self.shell : Ports::Shell
    @@shell ||= Ports::SystemShell.new
  end

  def self.logger : Ports::Logger
    @@logger ||= Ports::FileLogger.new(Paths.log_file)
  end

  # Рекурсивное копирование дерева без следования симлинкам: симлинки
  # пересоздаются (FileUtils.cp_r следует за симлинками на каталоги —
  # layout lib/<shard>/lib -> .., который делает shards для flat-резолва
  # зависимостей, уводит его в бесконечную рекурсию).
  def self.copy_tree(src : String, dst : String) : Nil
    Dir.mkdir_p(dst)
    Dir.each_child(src) do |entry|
      s = File.join(src, entry)
      d = File.join(dst, entry)
      if File.symlink?(s)
        File.symlink(File.readlink(s), d)
      elsif File.directory?(s)
        copy_tree(s, d)
      else
        FileUtils.cp(s, d)
      end
    end
  end
end

begin
  Carat.run(ARGV)
rescue e : Carat::Error
  STDERR.puts Carat.paint("carat: #{e.message}", :red)
  exit 1
end
