# Семантические версии: парсинг (v-префикс, пререлизы, build-метаданные
# нотации shard.lock), сравнение, распознавание git-тегов.

module Carat
  # ------------------------------------------------------------------
  # Ядро: semver
  # ------------------------------------------------------------------

  class SemVer
    include Comparable(SemVer)

    getter major : Int32
    getter minor : Int32
    getter patch : Int32
    getter pre : String?

    def initialize(@major : Int32, @minor : Int32, @patch : Int32, @pre : String? = nil)
    end

    def self.parse(raw : String) : self
      s = raw.strip
      s = s[1..] if s.starts_with?('v')
      # build-метаданные не влияют на порядок версий: identity вида
      # 0.10.0+git.commit.<sha> (нотация shard.lock) сравнивается как 0.10.0
      if plus = s.index('+')
        s = s[0...plus]
      end
      pre = nil
      if idx = s.index('-')
        pre = s[(idx + 1)..]
        s = s[0...idx]
      end
      parts = s.split('.').map { |p| p.to_i? || 0 }
      new(parts[0]? || 0, parts[1]? || 0, parts[2]? || 0, pre)
    end

    def <=>(other : SemVer) : Int32
      cmp = major <=> other.major
      return cmp unless cmp == 0
      cmp = minor <=> other.minor
      return cmp unless cmp == 0
      cmp = patch <=> other.patch
      return cmp unless cmp == 0
      a, b = pre, other.pre
      return 0 if a.nil? && b.nil?
      return 1 if a.nil? # релиз выше пререлиза
      return -1 if b.nil?
      a <=> b
    end

    def to_s(io : IO) : Nil
      io << major << '.' << minor << '.' << patch
      io << '-' << pre if pre
    end

    # Похоже ли имя git-тега на версию — для выбора старшего semver-тега
    # репозитория (резолв как у shards: последний релизный тег по умолчанию).
    def self.parsable?(raw : String) : Bool
      s = raw.strip
      s = s[1..] if s.starts_with?('v')
      !s.empty? && s.matches?(/\A\d+(\.\d+)*(-[0-9A-Za-z.-]+)?\z/)
    end
  end
end
