require 'net/http'
require 'json'
require "formula_installer"
require 'licensee'
require 'set'

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
      req['Authorization'] = "token e7754cf8f02a14c6225b0b273d9cf644152ee0ab"

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
        sleep 0.1
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

  def match_github_repo(f)
    match = f.stable.url.match %r{https?://github\.com/(downloads/)?(?<user>[^/]+)/(?<repo>[^/]+)/?.*}
    return unless match
    user = match[:user]
    repo = match[:repo].delete_suffix(".git")
    GitHub::Repo.new("#{user}/#{repo}", formula_name: f.name)
  end

  def license
    report_file = File.open "report.csv", "a+"

    already_processed = Set.new(report_file.readlines.map do |line|
      line.split(",")[0].chomp
    end)

    # all_considered_formula = %w[openssl readline python sqlite gettext glib icu4c xz gdbm pcre git libidn2 libevent
    # unbound libtiff gnutls libffi webp jpeg freetype llvm flake ocamlbuild libsecret flake8 gibo zabbix optipng lldpd
    # ettercap pius opencv youtube-dl pdf2json kumactl ttygif]
    #                              .map do
    # |name|
    #   Formulary.resolve(name)
    # end.to_a

    all_considered_formula = Formula.to_a.shuffle.slice(0, 10)

    all_considered_formula.sort { |f, g| f.name <=> g.name }.each do |f|
      if already_processed.include? f.name
        ohai "Skipping #{f}"
      elsif (github_repo = match_github_repo f)
        ohai "Fetching GitHub license for #{f}"

        github_repo.fetch_license
        report_file.write "#{github_repo.formula_name}, "\
          "#{github_repo.license&.spdx_id || ""}, "\
          "true\n"

      else
        ohai "Fetching license manually for #{f}"

        fi = FormulaInstaller.new(f)
        fi.ignore_deps = true
        fi.prelude
        targz_path = fi.fetch
        system("tar -xf #{targz_path} -C #{File.dirname(targz_path)}")

        path = "#{File.dirname(targz_path)}/#{f.name}/#{f.version}/"
        license = Licensee.license path
        report_file.write "#{f.name}, #{license&.spdx_id || ""}, false\n"
        report_file.flush

        system("rm #{targz_path}")
        system("rm -rf #{File.dirname(targz_path)}/#{f.name}")
      end
    end

    report_file.close

    # all_considered_formula.each do |f|
    #   found_github = f.stable.url.match %r{https?://github\.com/(downloads/)?(?<user>[^/]+)/(?<repo>[^/]+)/?.*} do
    #   |match_data|
    #     user = match_data[:user]
    #     repo = match_data[:repo].delete_suffix(".git")
    #     github_repos << GitHub::Repo.new("#{user}/#{repo}", formula_name: f.name)
    #   end
    #
    #   non_github_formulae << f unless found_github
    # end
    #
    # github_repos.each do |repo|
    #   repo.fetch_license
    #   if repo.license
    #   else
    #     report_file.write "#{repo.formula_name}, \n"
    #   end
    #   report_file.flush
    # end
    #
    # non_github_formulae.each do |f|
    # end
    #
    # report_file.close

    # sampled_repos = github_repos.shuffle
    # sampled_repos.each do |repo|
    #   repo.fetch_license
    #   puts "#{repo}, #{repo.license}, #{repo.license&.name}, #{repo.license&.key}"
    # end
    #
    # num_github_repos_with_license = sampled_repos.count do |repo|
    #   repo.license
    # end
    #
    # num_github_repos_with_recognized_license = sampled_repos.count do |repo|
    #   repo.license && repo.license.spdx_id != "NOASSERTION"
    # end
    #
    # puts "total formulae: #{all_considered_formula.count}"
    # puts "github formulae: #{github_repos.count}"
    # puts "sampled github formulae: #{sampled_repos.count}"
    # puts "sampled github formulae with license: #{num_github_repos_with_license}"
    # puts "sampled github formulae with recognized open-source license: #{num_github_repos_with_recognized_license}"
  end

end
