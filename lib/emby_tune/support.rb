# frozen_string_literal: true

# Output, prompts, the change plan, and small shell helpers shared by every check.
module EmbyTune
  module UI
    module_function

    def color(code, text)
      $stdout.tty? && ENV["NO_COLOR"].nil? ? "\e[#{code}m#{text}\e[0m" : text
    end

    def head(text)
      puts "\n#{color('1', text)}"
    end

    def ok(text)
      puts "  #{color('32', 'ok  ')}#{text}"
    end

    def warn(text)
      puts "  #{color('33', 'warn')} #{text}"
    end

    def change(text)
      puts "  #{color('35', 'fix ')}#{text}"
    end

    def dim(text)
      color("2", text)
    end
  end

  Change = Struct.new(:area, :title, :before, :after, :why, :apply, :needs_root, keyword_init: true)

  # Everything a run found: changes to apply, plus warnings and "ok" notes to print.
  class Plan
    attr_reader :changes, :warnings, :oks

    def initialize
      @changes = []
      @warnings = []
      @oks = []
    end

    def fix(area, title, before, after, why, needs_root: false, &apply)
      @changes << Change.new(area: area, title: title, before: before, after: after, why: why,
                             apply: apply, needs_root: needs_root)
    end

    def warn(area, msg)
      @warnings << [area, msg]
    end

    def ok(area, msg)
      @oks << [area, msg]
    end
  end

  Result = Struct.new(:out, :err, :ok)

  def self.die(msg)
    $stderr.puts "emby-tune: #{msg}"
    exit 1
  end

  def self.ask(prompt, secret: false)
    if secret && $stdin.tty?
      ($stdin.getpass(prompt) || "").strip
    else
      print prompt
      ($stdin.gets || "").strip
    end
  end

  def self.confirm(prompt)
    %w[y yes].include?(ask("#{prompt} [y/N] ").downcase)
  end

  def self.run(cmd, stdin_data: nil)
    out, err, status = Open3.capture3(*cmd, stdin_data: stdin_data.to_s)
    Result.new(out, err, status.success?)
  rescue Errno::ENOENT => e
    Result.new("", e.message, false)
  end

  def self.sudo
    return [] if Process.euid.zero?
    return ["sudo"] if which("sudo")

    die("this change needs root and sudo is not installed")
  end

  def self.root_run(cmd, stdin_data: nil)
    r = run(sudo + cmd, stdin_data: stdin_data)
    raise "#{cmd.join(' ')} failed: #{r.err.strip}" unless r.ok
  end

  def self.root_write(path, content)
    root_run(["mkdir", "-p", File.dirname(path)])
    root_run(["tee", path], stdin_data: content)
  end

  def self.read_text(path)
    File.read(path)
  rescue SystemCallError, IOError
    nil
  end

  def self.which(bin)
    ENV.fetch("PATH", "").split(":").map { |d| File.join(d, bin) }.find { |p| File.executable?(p) && !File.directory?(p) }
  end

  def self.existing_ancestor(path)
    p = path
    p = File.dirname(p) until p.nil? || p.empty? || File.exist?(p) || p == "/"
    p.nil? || p.empty? ? "/" : p
  end

  def self.unit_of(pid)
    read_text("/proc/#{pid}/cgroup").to_s[%r{/([^/\s]+\.service)}, 1]
  end

  def self.unit_props(unit, *props)
    run(["systemctl", "show", unit] + props.map { |p| "-p#{p}" }).out.lines
                                                                 .map { |l| l.strip.split("=", 2) }.select { |kv| kv.size == 2 }.to_h
  end
end
