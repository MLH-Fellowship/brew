require 'net/http'
require 'json'
require "formula_installer"
require 'licensee'
require 'set'
require "commands"
require "cli/parser"

module GitHub

  class License

    attr_accessor :spdx_id, :key, :name, :url

    def initialize(dict)
      @key = dict["key"]
      @name = dict["name"]
      @spdx_id = dict["spdx_id"]
      @url = dict["url"]
    end

    def to_s
      @spdx_id
    end

  end

  class Repo

    def initialize(full_name, formula_name: nil)
      @full_name = full_name
      @formula_name = formula_name
    end

    def fetch_license(uri_string=nil)
      uri_string ||= "https://api.github.com/repos/#{@full_name}"
      uri = URI(uri_string)
      req = Net::HTTP::Get.new(uri)
      req['Accept'] = 'application/vnd.github.v3+json'
      req['Authorization'] = "token #{ENV["GITHUB_API_TOKEN"]}"

      res = Net::HTTP.start(uri.hostname, uri.port, :use_ssl => true) { |http|
        http.request(req)
      }

      res_dict = JSON.parse(res.body)
      if res_dict["message"] == "Moved Permanently"
        fetch_license(res_dict["url"])
      else
        license_dict = res_dict["license"]

        puts "[#{@full_name}] GitHub message: #{res_dict["message"]}" if res_dict["message"]

        @license = License.new(license_dict) if license_dict

        # sleeping 1 second per API call should be enough to avoid rate-limiting issues
        # (3600 seconds / hour) * (hour / 5000 requests) < 1 second / request
        # sleep 0.1
      end
    end

    attr_reader :license
    attr_reader :formula_name

    def to_s
      @full_name
    end

  end

end

module Homebrew
  module_function

  def license_args

    Homebrew::CLI::Parser.new do
      usage_banner <<~EOS
        `license` [<options>]

        Get or modify the licenses of formulae.
      EOS
      switch "--fetch",
             description: "Fetch license information and append to `report.csv`."
      switch "--rewrite",
             description: "Rewrite existing formula with license information described in `report.csv`."
      switch :verbose
      switch :debug
      conflicts "--fetch", "--rewrite"
    end
  end

  def license
    license_args.parse

    if args.fetch?
      fetch
    elsif args.rewrite?
      rewrite
    else
      odie "Add a command"
    end
  end

  def fetch
    report_file = File.open "report.csv", "a+"

    already_processed = Set.new(report_file.readlines.map do |line|
      line.split(",")[0].chomp
    end)

    all_considered_formula = Formula.to_a

    stat_processed = 0
    stat_start = Time.now
    stat_total = all_considered_formula.count

    all_considered_formula.sort { |f, g| f.name <=> g.name }.each do |f|
      if already_processed.include? f.name
        oh1 "Skipping #{f}"
        stat_total -= 1

      elsif f.disabled?
        oh1 "Skipping #{f} because it has been disabled"

        write_report(report_file, f, nil, "disabled")

        stat_total -= 1

      elsif (github_repo = match_github_repo f)
        oh1 "Fetching GitHub license for #{f}"

        github_repo.fetch_license
        write_report(report_file, f, github_repo.license, "github")

        stat_processed += 1

      else
        oh1 "Fetching license manually for #{f}"

        fi = FormulaInstaller.new(f)
        fi.ignore_deps = true
        fi.prelude
        compressed_fp = fi.fetch
        if extract(compressed_fp.to_s)
          path = "#{File.dirname(compressed_fp)}/#{f.name}/#{f.version}/"
          license = Licensee.license path
          write_report(report_file, f, license, "")

          stat_processed += 1
        else
          opoo "Unable to extract #{f}"
          puts compressed_fp

          stat_total -= 1
        end
      end

      if stat_processed != 0
        linear_eta = stat_start + stat_total.to_f / stat_processed.to_f * (Time.now - stat_start)
        puts "#{stat_processed} / #{stat_total}, "\
          "eta: #{(linear_eta - Time.now).to_i}s, "\
          "time passed: #{(Time.now - stat_start).to_i }s"
      end
    end

    report_file.close
  end

  def write_report(file, f, license, message = nil, description = nil)
    file.write "#{f.name},#{license&.spdx_id || ""},#{message || ""},#{description || ""}\n"
    file.flush
  end

  def extract(path)
    Dir.chdir File.dirname(path) do
      return system("tar -xf #{path}") if path.end_with?(".bz2", ".gz", ".xz", ".tgz")
      return system("unzip #{path}") if path.end_with?(".zip")
      return false
    end
  end

  def match_github_repo(f)
    match = f.stable.url.match %r{https?://github\.com/(downloads/)?(?<user>[^/]+)/(?<repo>[^/]+)/?.*}
    return unless match
    user = match[:user]
    repo = match[:repo].delete_suffix(".git")
    GitHub::Repo.new("#{user}/#{repo}", formula_name: f.name)
  end

  def rewrite
    report_file = File.open "report.csv", "r"
    name_to_license = Hash.new
    report_file.readlines.each do |line|
      components = line.split(",")
      name_to_license[components[0]] = components[1] unless components[1] == "" || components[1] == "NOASSERTION"
    end
    report_file.close

    Formula.each do |f|
      puts f.name
      rewrite_formula name_to_license, f
    end
  end

  def rewrite_formula(name_to_license, formula)
    return unless name_to_license.has_key?(formula.name)

    formula_file = File.open formula.path
    lines = formula_file.readlines
    formula_file.close

    if (desc_index = lines.find_index { |line| line.match?(/.*desc\s*".*"\n/) })
      lines.insert(desc_index + 1, "  license \"#{name_to_license[formula.name]}\"\n")

      formula_file = File.open formula.path, "w"
      lines.each { |line| file.write line }
      formula_file.close
    end
  end

end
