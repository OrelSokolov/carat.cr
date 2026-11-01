# Резолв источника установки: локальный каталог, прямой git URL
# (https/ssh/git/file, scp-подобный), owner/repo и голое имя (GitHub).

module Carat
  # ------------------------------------------------------------------
  # Ядро: резолв источника
  # ------------------------------------------------------------------

  class Source
    enum Kind
      Local
      Git
    end

    getter kind : Kind
    getter location : String
    getter name : String? # подсказка имени (repo для owner/repo)

    def initialize(@kind : Kind, @location : String, @name : String? = nil)
    end
  end

  # Прямой git URL: схема https://host/... | ssh://user@host/... |
  # git:// | file:// — либо scp-подобный синтаксис git (user@host:path,
  # до двоеточия нет '/': git@github.com:owner/repo.git). Таким URL carat
  # доверяет как есть — любой git-хост (GitLab, Gitea, sr.ht, ...).
  GIT_URL     = /\A(?:https?|git|ssh|file):\/\//
  GIT_SCP_URL = /\A[^\/\s]+@[^\/\s]+:/

  def self.resolve_source(src : String) : Source
    if File.directory?(src)
      Source.new(Source::Kind::Local, File.expand_path(src))
    elsif src =~ GIT_URL || src =~ GIT_SCP_URL
      # Имя-подсказка для staging-каталога: последний сегмент после '/'
      # или ':' без финального .git (https://h/o/repo.git, git@h:o/repo.git,
      # git@h:repo.git → repo).
      name = src.chomp("/").split(/[:\/]/).last?.try &.gsub(/\.git\z/, "")
      Source.new(Source::Kind::Git, src, name)
    elsif src.count('/') == 1
      owner, repo = src.split('/', 2)
      Source.new(Source::Kind::Git, "https://github.com/#{owner}/#{repo}.git", repo)
    else
      # голое имя → конвенция github.com/<name>/<name>
      Source.new(Source::Kind::Git, "https://github.com/#{src}/#{src}.git", src)
    end
  end
end
