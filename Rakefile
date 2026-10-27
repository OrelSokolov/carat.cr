# frozen_string_literal: true

# carat — first-install helper.
#
#   rake build     # compile the release binary into bin/
#   rake install   # build + copy the binary to ~/.carat/bin + put that on PATH
#
# No packages, no sudo: carat is a plain console binary, the first copy in
# ~/.carat/bin is carat itself. Afterwards carat updates itself:
#
#   carat update OrelSokolov/carat.cr

WINDOWS = Gem.win_platform?

def binary
  WINDOWS ? "bin/carat.exe" : "bin/carat"
end

def carat_bin
  home = if WINDOWS
           ENV.fetch("USERPROFILE") { abort "rake install: USERPROFILE not set" }
         else
           ENV.fetch("HOME") { abort "rake install: HOME not set" }
         end
  File.join(home, ".carat", "bin")
end

desc "Compile the release binary into bin/"
task :build do
  mkdir_p "bin"
  sh "crystal build --release --no-color src/carat.cr -o #{binary}"
end

desc "First install: build, copy the binary to ~/.carat/bin, add it to PATH"
task install: :build do
  bin_dir = carat_bin
  mkdir_p bin_dir
  target = File.join(bin_dir, File.basename(binary))
  cp binary, target
  chmod 0o755, target
  puts "Installed #{target}"
  add_to_path(bin_dir)
end

# Appends ~/.carat/bin to PATH — idempotently.
# Unix: ~/.bashrc / ~/.zshrc (existing files; ~/.bashrc created if neither
# exists). Windows: the user PATH via setx-style registry write.
def add_to_path(bin_dir)
  if WINDOWS
    script = <<~PS
      $bin = '#{bin_dir.gsub("/", "\\")}'
      $path = [Environment]::GetEnvironmentVariable('Path', 'User')
      if (-not (($path -split ';') -contains $bin)) {
        [Environment]::SetEnvironmentVariable('Path', ($path + ';' + $bin), 'User')
        Write-Output "PATH: added $bin to the user PATH"
      } else {
        Write-Output "PATH: $bin already on the user PATH"
      }
    PS
    sh "powershell", "-NoProfile", "-Command", script.strip
  else
    line = 'export PATH="$HOME/.carat/bin:$PATH"'
    rcs = %w[.bashrc .zshrc].map { |rc| File.expand_path(rc, Dir.home) }
    touched = rcs.select { |file| File.exist?(file) }
    touched = [rcs.first] if touched.empty? # bash-only box: create ~/.bashrc
    touched.each do |file|
      next if File.read(file).include?(line)

      File.open(file, "a") { |f| f.puts "", "# added by carat install", line }
      puts "PATH: added to #{file}"
    end
    puts %(restart your shell, or run: #{line})
  end
end
