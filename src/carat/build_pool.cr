# Пул параллельных сборок: ширина из ядер и MemAvailable, замер peak
# RSS компилятора на warm-up, RAM-гейт очереди, ретрай упавших сборок,
# per-worker CRYSTAL_CACHE_DIR (см. класс BuildPool).

module Carat
  # ------------------------------------------------------------------
  # Ядро: worker pool для параллельной сборки
  # ------------------------------------------------------------------

  # Параллельные `crystal build` масштабируются ~N по wall-clock (один
  # процесс — фактически одно ядро на кодоген), но каждый компилятор
  # держит ~1-2 ГБ RAM, поэтому фиксированная ширина пула, подобранная
  # под одну машину, на другой уходит в OOM. Вместо этого ширина
  # выводится из ТЕКУЩЕГО состояния машины (Sysinfo): ядра ограничивают
  # сверху, MemAvailable / замеренный peak RSS компилятора — снизу:
  #
  #   workers = min(ядра, MemAvailable * 0.7 / peak_rss, 8, |jobs|)
  #
  # Peak RSS не угадывается, а измеряется: первая сборка греет слот j0
  # кэша компилятора, пока сэмплируется RSS её процесса (carat + все
  # дети — crystal, cc); слот затем клонируется в пустые слоты воркеров
  # (паттерн из Rakefile egui.cr, обобщённый). Перед выдачей каждого
  # следующего задания гейт перепроверяет MemAvailable и придерживает
  # очередь, когда свободной памяти меньше (peak + запас) — случай «один
  # бинарник тяжелее остальных» замедляет пул, а не валит его. Сборка,
  # всё-таки умершая от OOM (exit 137 / SIGKILL), после осушения пула
  # ретраится один раз последовательно.
  #
  # Конкурентные компиляторы также гоняются на общем ~/.cache/crystal
  # (tmp-переименования), поэтому каждый воркер получает свой
  # персистентный CRYSTAL_CACHE_DIR: <корень шарда>/.carat/cache/jN —
  # он живёт между запусками, второй и дальнейшие прогоны тёплые.
  # CARAT_JOBS=N отключает адаптивный подбор (бенчмарки, A/B-прогоны).
  class BuildPool
    MAX_WORKERS = 8
    # Запас свободной RAM ниже наблюдаемого peak RSS (гейт очереди).
    # (одиночные _i64-литералы: `512 * 1024_i64` в Crystal выводится как
    # Int32 из-за сворачивания литералов)
    MARGIN_KB = 524_288_i64
    # Пока warm-up не измерил реальный след: ~2 ГБ на release-сборку
    # масштаба egui-cr.
    FALLBACK_PEAK_KB = 2_097_152_i64
    # Пол измеренного peak: крошечная сборка не должна раздувать пул до
    # 8 воркеров (она и так собирается секунды — ширина не важна).
    MIN_PEAK_KB = 262_144_i64

    record Job, name : String, run : Proc(Hash(String, String), Nil)

    @peak_kb : Int64 = FALLBACK_PEAK_KB

    def initialize(@dir : String, @jobs : Array(Job))
      @cache_root = File.join(@dir, ".carat", "cache")
      Dir.mkdir_p(@cache_root)
    end

    def run : Nil
      return if @jobs.empty?
      forced = ENV["CARAT_JOBS"]?.try(&.to_i?).try { |n| n.clamp(1, MAX_WORKERS) }
      workers = (forced || initial_workers).clamp(1, @jobs.size)
      if workers == 1 || @jobs.size == 1
        @jobs.each do |job|
          raise Error.new("build failed: #{job.name}") unless run_one(job, 0)
        end
        return
      end
      warm = @jobs.first
      unless warm_up(warm)
        # не исключён OOM при стартовой оценке — один последовательный ретрай
        raise Error.new("build failed: #{warm.name}") unless run_one(warm, 0)
      end
      workers = (forced || workers_for(@peak_kb)).clamp(1, @jobs.size)
      clone_warm_cache(workers)
      report(workers, forced)
      failures = run_pool(@jobs[1..], workers)
      # ретрай по одному: падение в пуле могло быть разовым перекосом памяти
      still = failures.reject { |job| run_one(job, 0) }
      raise Error.new("build failed: #{still.map(&.name).sort.join(", ")}") unless still.empty?
    end

    # Запуск `crystal` с env-переопределениями (CRYSTAL_CACHE_DIR) —
    # вывод наследуется, окружение = текущее + overrides.
    def self.spawn_process(command : String, args : Array(String), cwd : String,
                           overrides : Hash(String, String)) : Bool
      process = Process.new(command, args, chdir: cwd, env: ENV.to_h.merge!(overrides),
        output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
      process.wait.success?
    end

    # Стартовая ширина до замера peak: консервативный fallback.
    private def initial_workers : Int32
      workers_for(FALLBACK_PEAK_KB)
    end

    private def workers_for(peak_kb : Int64) : Int32
      workers = self.class.core_count || 4
      if mem = Sysinfo.memory
        mem_bound = (mem.available_kb.to_f * 0.7 / peak_kb).to_i
        workers = {workers, mem_bound}.min
      end
      workers.clamp(1, MAX_WORKERS)
    end

    # Число ядер — размер per-core массива sysinfo (nil на платформах
    # без бэкенда CPU).
    def self.core_count : Int32?
      Sysinfo.refresh_cpu
      size = Sysinfo.cpu_percentages.size
      size > 0 ? size : nil
    end

    # Первая сборка на кэше j0 + сэмплирование RSS её дерева процессов
    # (250 мс интервал). Замеренный peak становится знаменателем формулы
    # ширины и порогом гейта.
    private def warm_up(job : Job) : Bool
      done = Channel(Bool).new
      spawn { done.send(run_one(job, 0)) }
      peak = 0_i64
      loop do
        select
        when ok = done.receive
          @peak_kb = peak < MIN_PEAK_KB ? MIN_PEAK_KB : peak
          puts Carat.paint("Warm-up: #{job.name} built, peak compiler RSS #{@peak_kb // 1024} MB", :blue)
          return ok
        when timeout(0.25.seconds)
          begin
            Sysinfo.refresh_processes
            tree = Sysinfo.process_tree_memory_kb(Process.pid.to_i32)
            peak = tree if tree > peak
          rescue File::Error
            # гонка в /proc (процесс исчез посреди скана) — пропускаем сэмпл
          end
        end
      end
    end

    # Тёплый j0 клонируется в ПУСТЫЕ слоты воркеров (полупустые цели от
    # прерванного прогона пересоздаются). Уже населённые слоты не трогаем.
    private def clone_warm_cache(workers : Int32) : Nil
      warm = cache_dir(0)
      (1...workers).each do |i|
        dst = cache_dir(i)
        next if Dir.exists?(dst) && !Dir.empty?(dst)
        FileUtils.rm_rf(dst)
        FileUtils.cp_r(warm, dst)
      end
    end

    private def run_pool(jobs : Array(Job), workers : Int32) : Array(Job)
      queue = Channel(Job).new(jobs.size)
      jobs.each { |job| queue.send(job) }
      queue.close
      failures = [] of Job
      lock = Mutex.new
      done = Channel(Nil).new
      workers.times do |i|
        spawn do
          loop do
            break unless job = queue.receive?
            gate
            unless run_one(job, i)
              lock.synchronize { failures << job }
            end
          end
          done.send(nil)
        end
      end
      workers.times { done.receive }
      failures
    end

    # Придержать очередь, пока свободной RAM меньше (peak + запас):
    # уже работающие сборки завершатся и освободят память — дедлока нет.
    private def gate : Nil
      while (mem = Sysinfo.memory) && mem.available_kb < @peak_kb + MARGIN_KB
        sleep(0.3.seconds)
      end
    end

    private def run_one(job : Job, cache_index : Int32) : Bool
      begin
        job.run.call({"CRYSTAL_CACHE_DIR" => cache_dir(cache_index)})
        true
      rescue e : Carat::Error
        puts Carat.paint("carat: #{e.message}", :red)
        false
      end
    end

    private def cache_dir(i : Int32) : String
      File.join(@cache_root, "j#{i}")
    end

    private def report(workers : Int32, forced : Int32?) : Nil
      mem = Sysinfo.memory.try { |m| m.available_kb // 1024 }
      puts Carat.paint("Build pool: #{workers} workers" \
                       "#{forced ? " (CARAT_JOBS=#{forced})" : ""} — cores=#{self.class.core_count}," \
                       " RAM available=#{mem ? "#{mem} MB" : "n/a"}, peak build RSS=#{@peak_kb // 1024} MB", :blue)
    end
  end
end
