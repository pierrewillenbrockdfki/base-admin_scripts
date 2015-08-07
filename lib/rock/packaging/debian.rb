require 'find'
require 'autoproj'
require 'autobuild'
require 'tmpdir'
require 'utilrb'

module Autoproj
    module Packaging

        # Directory for temporary data to
        # validate obs_packages
        BUILD_DIR=File.join(Autoproj.root_dir, "build/rock-packager")
        LOG_DIR=File.join(Autoproj.root_dir, BUILD_DIR, "logs")
        LOCAL_TMP = File.join(BUILD_DIR,".rock_packager")

        class Packager
            extend Logger::Root("Packager", Logger::INFO)

            attr_accessor :build_dir
            attr_accessor :log_dir
            attr_accessor :local_tmp_dir

            def initialize
                @build_dir = BUILD_DIR
                @log_dir = LOG_DIR
                @local_tmp_dir = LOCAL_TMP
            end

            def max_one_distribution(distributions)
                distribution = nil
                if !distributions.kind_of?(Array)
                    raise ArgumentError, "max_one_distribution: expecting Array as argument, but got: #{distributions}"
                end

                if distributions.size > 1
                    raise ArgumentError, "Unsupported requests. You provided more than one distribution where maximum one 1 allowed"
                elsif distributions.empty?
                    Packager.warn "You provided no distribution for debian package generation."
                else
                    distribution = distributions.first
                end
                distribution
            end

            def prepare_source_dir(pkg, options = Hash.new)

                distribution = max_one_distribution(options[:distributions])

                Packager.debug "Preparing source dir #{pkg.name}"
                if existing_source_dir = options[:existing_source_dir]
                    Packager.debug "Preparing source dir #{pkg.name} from existing: '#{existing_source_dir}'"
                    pkg_dir = File.join(@build_dir, debian_name(pkg))
                    if not File.directory?(pkg_dir)
                        FileUtils.mkdir_p pkg_dir
                    end

                    target_dir = File.join(pkg_dir, dir_name(pkg, distribution))
                    FileUtils.cp_r existing_source_dir, target_dir

                    pkg.srcdir = target_dir
                else
                    Autoproj.manifest.load_package_manifest(pkg.name)

                    # Test whether there is a local
                    # version of the package to use.
                    # If it is not available import package
                    # from the original source
                    if pkg.importer.kind_of?(Autobuild::Git)
                        if not File.exists?(pkg.srcdir)
                            Packager.debug "Retrieving remote git repository of '#{pkg.name}'"
                            pkg.importer.import(pkg)
                        else
                            Packager.debug "Using locally available git repository of '#{pkg.name}'"
                        end
                        pkg.importer.repository = pkg.srcdir
                    end

                    pkg.srcdir = File.join(@build_dir, debian_name(pkg), dir_name(pkg, distribution))
                    begin
                        Packager.debug "Importing repository to #{pkg.srcdir}"
                        pkg.importer.import(pkg)
                    rescue Exception => e
                        if not e.message =~ /failed in patch phase/
                            raise
                        else
                            Packager.warn "Patching #{pkg.name} failed"
                        end
                    end

                    Dir.glob(File.join(pkg.srcdir, "*-stamp")) do |file|
                        FileUtils.rm_f file
                    end
                end
            end

            def self.obs_package_name(pkg)
                "rock-" + pkg.name.gsub(/[\/_]/, '-').downcase
            end
        end

        class OBS

            @@obs_cmd = "osc"

            def self.obs_cmd
                @@obs_cmd
            end

            # Update the open build local checkout
            # using a given checkout directory and the pkg name
            # use a specific file pattern to set allowed files
            # source directory
            # obs_dir target obs checkout directory
            # src_dir where the source dir is
            # pkg_name
            # allowed file patterns
            def self.update_dir(obs_dir, src_dir, pkg_obs_name, file_suffix_patterns = ".*", commit = true)
                pkg_obs_dir = File.join(obs_dir, pkg_obs_name)
                if !File.directory?(pkg_obs_dir)
                    FileUtils.mkdir_p pkg_obs_dir
                    system("#{obs_cmd} add #{pkg_obs_dir}")
                end

                # sync the directory in build/obs and the target directory based on an existing
                # files pattern
                files = []
                file_suffix_patterns.map do |p|
                    # Finding files that exist in the source directory
                    # needs to handle ruby-hoe_0.20130113/*.dsc vs. ruby-hoe-yard_0.20130113/*.dsc
                    # and ruby-hoe/_service
                    glob_exp = File.join(src_dir,pkg_obs_name,"*#{p}")
                    files += Dir.glob(glob_exp)
                end
                files = files.flatten.uniq
                Packager.debug "update directory: files in src #{files}"

                # prepare pattern for target directory
                expected_files = files.map do |f|
                    File.join(pkg_obs_dir, File.basename(f))
                end
                Packager.debug "target directory: expected files: #{expected_files}"

                existing_files = Dir.glob(File.join(pkg_obs_dir,"*"))
                Packager.debug "target directory: existing files: #{existing_files}"

                existing_files.each do |existing_path|
                    if not expected_files.include?(existing_path)
                        Packager.warn "OBS: deleting #{existing_path} -- not present in the current packaging"
                        FileUtils.rm_f existing_path
                        system("#{obs_cmd} rm #{existing_path}")
                    end
                end

                # Add the new unchanged files
                files.each do |path|
                    target_file = File.join(pkg_obs_dir, File.basename(path))
                    exists = File.exists?(target_file)
                    if exists
                        if File.read(path) == File.read(target_file)
                            Packager.info "OBS: #{target_file} is unchanged, skipping"
                        else
                            Packager.info "OBS: #{target_file} updated"
                            FileUtils.cp path, target_file
                        end
                    else
                        FileUtils.cp path, target_file
                        system("#{obs_cmd} add #{target_file}")
                    end
                end

                if commit
                    Packager.info "OBS: committing #{pkg_obs_dir}"
                    system("#{obs_cmd} ci #{pkg_obs_dir} -m \"autopackaged using autoproj-packaging tools\"")
                else
                    Packager.info "OBS: not commiting #{pkg_obs_dir}"
                end
            end

            # List the existing package in the projects
            # The list will contain only the name, suffix '.deb' has
            # been removed
            def self.list_packages(project, repository, architecture = "i586")
                result = %x[#{obs_cmd} ls -b -r #{repository} -a #{architecture} #{project}].split("\n")
                pkg_list = result.collect { |pkg| pkg.sub(/(_.*)?.deb/,"") }
                pkg_list
            end

            def self.resolve_dependencies(package_name)
                record = `apt-cache depends #{package_name}`.split("\n").map(&:strip)
                if $?.exitstatus != 0
                    raise
                end

                depends_on = []
                record.each do |line|
                    if line =~ /^\s*Depends:\s*[<]?([^>]*)[>]?/
                        depends_on << $1.strip
                    end
                end

                depends_on
            end
        end

        # Packaging details:
        # - one main temporary folder in use: <autoproj-root>/build/obs/
        # - in the temp folder we create one folder per package to handle the packaging
        #   this folder can be synced with the target folder of the local checkout of the OBS
        # - checking update currently on checks for changes on the source data (so if patches change it
        #   is not recognized)
        # - to facilitate patching etc. an 'overlay' directory is used which is just copied during the
        #   build process -- currently only for gem handling and injecting fixes
        #
        # Resources:
        # * http://www.debian.org/doc/manuals/maint-guide/dreq.en.html
        # * http://cdbs-doc.duckcorp.org/en/cdbs-doc.xhtml
        class Debian < Packager
            TEMPLATES = File.expand_path(File.join("templates", "debian"), File.dirname(__FILE__))

            # Package like tools/rtt etc. require a custom naming schema, i.e. the base name rtt should be used for tools/rtt
            attr_reader :package_aliases

            attr_reader :existing_debian_directories

            # List of gems, which need to be converted to debian packages
            attr_accessor :ruby_gems

            # List of rock gems, ruby_packages that have been converted to debian packages
            attr_accessor :ruby_rock_gems

            # List of osdeps, which are needed by the set of packages
            attr_accessor :osdeps

            # install directory if not given set to /opt/rock
            attr_accessor :rock_install_directory

            def initialize(existing_debian_directories)
                super()
                @existing_debian_directories = existing_debian_directories
                @ruby_gems = Array.new
                @ruby_rock_gems = Array.new
                @osdeps = Array.new
                @package_aliases = Hash.new
                @debian_version = Hash.new
                @rock_install_directory = "/opt/rock"

                if not File.exists?(local_tmp_dir)
                    FileUtils.mkdir_p local_tmp_dir
                end

                if not File.exists?(log_dir)
                    FileUtils.mkdir_p log_dir
                end
            end

            def canonize(name)
                name.gsub(/[\/_]/, '-').downcase
            end

            # Extract the base name from a path description
            # e.g. tools/metaruby => metaruby
            def basename(name)
                if name =~ /.*\/(.*)/
                    name = $1
                end
                name
            end

            def add_package_alias(pkg_name, pkg_alias)
                @package_aliases[pkg_name] = pkg_alias
            end

            # The debian name of a package -- either
            # rock-<canonized-package-name>
            # or for ruby packages
            # ruby-<canonized-package-name>
            def debian_name(pkg)
                name = pkg.name
                if pkg.kind_of?(Autobuild::Ruby)
                    debian_ruby_name(pkg.name)
                    if @package_aliases.has_key?(name)
                        name = @package_aliases[name]
                    end
                end

                if pkg.kind_of?(Autobuild::Ruby)
                    debian_ruby_name(name)
                else
                    "rock-" + canonize(name)
                end
            end

            def debian_ruby_name(name)
                "ruby-" + canonize(name)
            end

            def debian_version(pkg, distribution, revision = "1")
                if !@debian_version.has_key?(pkg.name)
                    @debian_version[pkg.name] = (pkg.description.version || "0") + "." + Time.now.strftime("%Y%m%d%H%M") + "-" + revision
                    if distribution
                        @debian_version[pkg.name] += '~' + distribution
                    end
                end
                @debian_version[pkg.name]
            end

            # Plain version is the version string without the revision
            def debian_plain_version(pkg, distribution)
                if !@debian_version.has_key?(pkg.name)
                    # initialize version string
                    debian_version(pkg, distribution)
                end

                # remove the revision and the distribution
                # to get the plain version
                @debian_version[pkg.name].gsub(/[-~].*/,"")
            end

            def versioned_name(pkg, distribution)
                debian_name(pkg) + "_" + debian_version(pkg, distribution)
            end

            def plain_versioned_name(pkg, distribution)
                debian_name(pkg) + "_" + debian_plain_version(pkg, distribution)
            end

            def dir_name(pkg, distribution)
                versioned_name(pkg, distribution)
            end

            def packaging_dir(pkg)
                File.join(@build_dir, debian_name(pkg))
            end

            def create_flow_job(name, selection, flavor, force = false)
                Packager.info ("#{selection.size} packages selected")
                flow = Array.new
                flow[0] = Array.new
                x = 1
                debug = false
                size = 0
                while !selection.empty? do
                    if size == selection.size
                        puts "entering debug mode"
                        debug = true
                    end
                    size = selection.size
                    flow[x] = Array.new
                    flow_old = flow.flatten
                    selection.each do |pkg_name|
                        pkg = Autoproj.manifest.package(pkg_name).autobuild
                        if deps_fulfilled(flow_old.flatten, pkg, flow, debug)
                            flow[x] << debian_name(pkg)
                            selection.delete(pkg_name)
                            #puts debian_name(pkg)
                        end
                    end

                    x += 1
                end

                create_flow_job_xml(name, flow, flavor, force)
            end

            def deps_fulfilled(deps, pkg, flow, debug = false)
                pkg_deps = dependencies(pkg)
                pkg_deps[0].each do |dep|
                    if !deps.include? dep
                        #if (debian_name(pkg) == "data_processing/orogen/type_to_vector")
                        if debug
                            puts "Missing: #{dep} for #{pkg.name}"
                            #puts "the dep's deps: #{dependencies(Autoproj.manifest.package(dep).autobuild)}"
                            exit -1
                        end
                        return false
                    end
                end
                pkg_deps[1].each do |dep|
                    if (dep.start_with? "ruby-") && (!flow[0].include? dep[5..dep.size])
                        flow[0] << dep[5..dep.size]
                    end
                end
                true
            end

            def create_flow_job_xml(name, flow, flavor, force = false)
                gems = flow[0].uniq
                flow.delete_at(0)

                # Create-unlock-job
                safe_level = nil
                trim_mode = "%<>"
                template = ERB.new(File.read(File.join(File.dirname(__FILE__), "templates", "jenkins-unlock-job.xml")), safe_level, trim_mode)
                rendered = template.result(binding)
                File.open("unlock.xml", 'w') do |f|
                      f.write rendered
                end
                if not system("java -jar ~/jenkins-cli.jar -s http://localhost:8080/ create-job 'unlock' --username test --password test < unlock.xml")
                    system("java -jar ~/jenkins-cli.jar -s http://localhost:8080/ update-job 'unlock' --username test --password test < unlock.xml")
                end

                template = ERB.new(File.read(File.join(File.dirname(__FILE__), "templates", "jenkins-flow-job.xml")), safe_level, trim_mode)
                rendered = template.result(binding)
                File.open("#{name}.xml", 'w') do |f|
                      f.write rendered
                end

                if force
                    system("java -jar ~/jenkins-cli.jar -s http://localhost:8080/ update-job '#{name}' --username test --password test < #{name}.xml")
                else
                    system("java -jar ~/jenkins-cli.jar -s http://localhost:8080/ create-job '#{name}' --username test --password test < #{name}.xml")
                end
            end

            def update_list(pkg, file)
                if File.exist? file
                    list = YAML.load_file(file)
                else
                    list = Array.new
                end
                if pkg.is_a? String
                    list << {pkg => {"debian,ubuntu" => debian_ruby_name(pkg)}}
                    list.uniq!
                else
                    list << {pkg.name => {"debian,ubuntu" => debian_name(pkg)}}
                    list.uniq!
                end
                File.open(file, 'w') {|f| f.write list.to_yaml }
            end

            # Create a jenkins job for a rock package (which is not a ruby package)
            def create_package_job(pkg, options = Hash.new, force = false)
                    options[:type] = :package
                    options[:debian_name] = debian_name(pkg)
                    options[:dir_name] = debian_name(pkg)
                    options[:job_name] = debian_name(pkg)

                    deps_rock_packages, deps_osdeps_packages = dependencies(pkg)
                    Packager.info "Dependencies of #{pkg.name}: rock: #{deps_rock_packages}, osdeps: #{deps_osdeps_packages}"

                    # Prepare upstream dependencies
                    deps = deps_rock_packages.join(", ")
                    if !deps.empty?
                        deps += ", "
                    end
                    options[:dependencies] = deps
                    create_job(pkg.name, options, force)
            end

            # Create a jenkins job for a ruby package
            def create_ruby_job(gem_name, options = Hash.new, force = false)
                options[:type] = :gem
                options[:dir_name] = debian_ruby_name(gem_name)
                options[:debian_name] = debian_ruby_name(gem_name)
                options[:job_name] = gem_name
                create_job(gem_name, options, force)
            end


            # Create a jenkins job
            def create_job(package_name, options = Hash.new, force = false)
                options[:architectures] ||= [ 'amd64','i386','armhf' ]
                options[:distributions] ||= [ 'trusty','jessie' ]
                options[:job_name] ||= package_name

                combinations = combination_filter(options[:architectures], options[:distributions])


                Packager.info "Creating jenkins-debian-glue job with"
                Packager.info "         options: #{options}"
                Packager.info "         combination filter: #{combinations}"

                safe_level = nil
                trim_mode = "%<>"
                template = ERB.new(File.read(File.join(File.dirname(__FILE__), "templates", "jenkins-debian-glue-job.xml")), safe_level, trim_mode)
                rendered = template.result(binding)
                rendered_filename = File.join("/tmp","#{options[:job_name]}.xml")
                File.open(rendered_filename, 'w') do |f|
                      f.write rendered
                end

                username = "test"
                password = "test"

                update_or_create = "create-job"
                if force
                    update_or_create = "update-job"
                end
                if system("java -jar ~/jenkins-cli.jar -s http://localhost:8080/ #{update_or_create} '#{options[:job_name].gsub '_', '-'}' --username #{username} --password #{password} < #{rendered_filename}")
                    Packager.info "job #{options[:job_name]}': #{update_or_create} from #{rendered_filename}"
                elsif force
                    if system("java -jar ~/jenkins-cli.jar -s http://localhost:8080/ create-job '#{options[:job_name].gsub '_', '-'}' --username #{username} --password #{password} < #{rendered_filename}")
                        Packager.info "job #{options[:job_name]}': create-job from #{rendered_filename}"
                    end
                end
            end

            def combination_filter(architectures, distributions)
                Packager.info "Filter combinations of: archs #{architectures} , dists: #{distributions}"
                whitelist = [
                    ["vivid", "amd64"],
                    ["vivid", "i386"],

                    ["trusty","amd64"],
                    ["trusty","i386"],

                    ["precise","amd64"],
                    ["precise","i386"],

                    ["wheezy","armel"],
                    ["wheezy","armhf"],

                    # arm64 available from jessie onwards:
                    #     https://wiki.debian.org/Arm64Port

                    ["jessie","amd64"],
                    ["jessie","i386"],
                    ["jessie","armhf"],
                    ["jessie","armel"],

                    ["sid","amd64"],
                    ["sid","i386"],
                    ["sid","armhf"],
                    ["sid","armel"]
                ]
                ret = ""
                and_placeholder = " &amp;&amp; "
                architectures.each do |arch|
                    distributions.each do |dist|
                        if !whitelist.include? [dist, arch]
                            ret += "#{and_placeholder} !(distribution == '#{dist}' &amp;&amp; architecture == '#{arch}')"
                        end
                    end
                end

                # Cut the first and_placeholder away
                ret = ret[and_placeholder.size..-1]
            end

            def self.list_all_jobs
                username = "test"
                password = "test"

                jobs_file = "/tmp/jenkins-jobs"
                # java -jar /home/rimresadmin/jenkins-cli.jar -s http://localhost:8080 help
                cmd = "java -jar ~/jenkins-cli.jar -s http://localhost:8080/ list-jobs --username #{username} --password #{password} > #{jobs_file}"
                if !system(cmd)
                    raise RuntimeError, "Failed to list all jobs using: #{cmd}"
                end

                all_jobs = []
                File.open(jobs_file,"r") do |file|
                    all_jobs = file.read.split("\n")
                end
                all_jobs
            end

            def self.cleanup_all_jobs
                all_jobs = list_all_jobs
                max_count = all_jobs.size
                i = 1
                all_jobs.each do |job|
                    Packager.info "Cleanup job #{i}/#{max_count}"
                    cleanup_job job
                    i += 1
                end
            end

            def self.remove_all_jobs
                all_jobs = list_all_jobs.delete_if{|job| job.start_with? 'a_' or job.start_with? 'b_'}
                max_count = all_jobs.size
                i = 1
                all_jobs.each do |job|
                    Packager.info "Remove job #{i}/#{max_count}"
                    remove_job job
                    i += 1
                end
            end

            # Cleanup job of a given name
            def self.cleanup_job(job_name)
                username = "test"
                password = "test"
                # java -jar /home/rimresadmin/jenkins-cli.jar -s http://localhost:8080 help delete-builds
                # java -jar jenkins-cli.jar delete-builds JOB RANGE
                # Delete build records of a specified job, possibly in a bulk.
                #   JOB   : Name of the job to build
                #   RANGE : Range of the build records to delete. 'N-M', 'N,M', or 'N'
                cmd = "java -jar ~/jenkins-cli.jar -s http://localhost:8080/ delete-builds '#{job_name}' '1-10000' --username #{username} --password #{password}"
                Packager.info "job '#{job_name}': cleanup with #{cmd}"
                if !system(cmd)
                    Packager.warn "job '#{job_name}': cleanup failed"
                end
            end

            # Remove job of a given name
            def self.remove_job(job_name)
                username = "test"
                password = "test"
                #java -jar /home/rimresadmin/jenkins-cli.jar -s http://localhost:8080 help delete-job
                #java -jar jenkins-cli.jar delete-job VAL ...
                #    Deletes job(s).
                #     VAL : Name of the job(s) to delete
                cmd = "java -jar ~/jenkins-cli.jar -s http://localhost:8080/ delete-job '#{job_name}' --username #{username} --password #{password}"
                Packager.info "job '#{job_name}': remove with #{cmd}"
                if !system(cmd)
                    Packager.warn "job '#{job_name}': remove failed"
                end
            end
            # Commit changes of a debian package using dpkg-source --commit
            # in a given directory (or the current one by default)
            def dpkg_commit_changes(patch_name, directory = Dir.pwd)
                Dir.chdir(directory) do
                    Packager.debug ("commit changes to debian pkg: #{patch_name}")
                    # Since dpkg-source will open an editor we have to
                    # take this approach to make it pass directly in an
                    # automated workflow
                    ENV['EDITOR'] = "/bin/true"
                    `dpkg-source --commit . #{patch_name}`
                end
            end

            # Compute dependencies of this package
            # Returns [rock_packages, osdeps_packages]
            def dependencies(pkg)
                pkg.resolve_optional_dependencies
                deps_rock_packages = pkg.dependencies.map do |pkg_name|
                    debian_name(Autoproj.manifest.package(pkg_name).autobuild)
                end.sort
                Packager.debug "'#{pkg.name}' with rock package dependencies: '#{deps_rock_packages}'"

                pkg_osdeps = Autoproj.osdeps.resolve_os_dependencies(pkg.os_packages)
                # There are limitations regarding handling packages with native dependencies
                #
                # Currently gems need to converted into debs using gem2deb
                # These deps dependencies are updated here before uploading a package
                #
                # Generation of the debian packages from the gems can be done in postprocessing step
                # i.e. see convert_gems

                deps_osdeps_packages = []
                native_package_manager = Autoproj.osdeps.os_package_handler
                _, native_pkg_list = pkg_osdeps.find { |handler, _| handler == native_package_manager }

                deps_osdeps_packages += native_pkg_list if native_pkg_list
                Packager.debug "'#{pkg.name}' with osdeps dependencies: '#{deps_osdeps_packages}'"

                # Update global list
                @osdeps += deps_osdeps_packages

                non_native_handlers = pkg_osdeps.collect do |handler, pkg_list|
                    if handler != native_package_manager
                        [handler, pkg_list]
                    end
                end.compact

                non_native_handlers.each do |pkg_handler, pkg_list|
                    # Convert native ruby gems package names to rock-xxx
                    if pkg_handler.kind_of?(Autoproj::PackageManagers::GemManager)
                        pkg_list.each do |name,version|
                            @ruby_gems << [name,version]
                            deps_osdeps_packages << debian_ruby_name(name)
                        end
                    else
                        raise ArgumentError, "cannot package #{pkg.name} as it has non-native dependencies (#{pkg_list}) -- #{pkg_handler.class} #{pkg_handler}"
                    end
                end

                # Remove duplicates
                @osdeps.uniq!
                @ruby_gems.uniq!

                # Return rock packages and osdeps
                [deps_rock_packages, deps_osdeps_packages]
            end

            def generate_debian_dir(pkg, dir, distribution)
                existing_dir = File.join(existing_debian_directories, pkg.name)
                template_dir =
                    if File.directory?(existing_dir)
                        existing_dir
                    else
                        TEMPLATES
                    end

                dir = File.join(dir, "debian")
                FileUtils.mkdir_p dir
                package = pkg
                debian_name = debian_name(pkg)
                debian_version = debian_version(pkg, distribution)
                versioned_name = versioned_name(pkg, distribution)

                deps_rock_packages, deps_osdeps_packages = dependencies(pkg)
                # Filter ruby versions out -- we assume chroot has installed all
                # ruby versions
                #
                # This is a workaround, since the information about required packages
                # comes from the build server platform and might not correspond
                # with the target platform
                #
                # Right approach: bootstrap within chroot and generate source packages
                # in the chroot
                deps_osdeps_packages = deps_osdeps_packages.select do |name|
                    name !~ /^ruby[0-9][0-9.]*/
                end
                # Filter out clang
                deps_osdeps_packages = deps_osdeps_packages.select do |name|
                    name !~ /clang/
                end
                deps_osdeps_packages = deps_osdeps_packages.select do |name|
                    name !~ /llvm/
                end

                Packager.info "Required OS Deps: #{deps_osdeps_packages}"

                Find.find(template_dir) do |path|
                    next if File.directory?(path)
                    template = ERB.new(File.read(path), nil, "%<>", path.gsub(/[^w]/, '_'))
                    rendered = template.result(binding)

                    target_path = File.join(dir, Pathname.new(path).relative_path_from(Pathname.new(template_dir)).to_s)
                    FileUtils.mkdir_p File.dirname(target_path)
                    File.open(target_path, "w") do |io|
                        io.write(rendered)
                    end
                end
            end

            # Package the given package
            # if an existing source directory is given this will be used
            # for packaging, otherwise the package will be bootstrapped
            def package(pkg, options = Hash.new)

                options, unknown_options = Kernel.filter_options options,
                    :force_update => false,
                    :existing_source_dir => nil,
                    :patch_dir => nil,
                    :package_set_dir => nil,
                    :distributions => []

                if options[:force_update]
                    dirname = File.join(build_dir, debian_name(pkg))
                    if File.directory?(dirname)
                        Packager.info "Debian: rebuild requested -- removing #{dirname}"
                        FileUtils.rm_rf(dirname)
                    end
                end

                prepare_source_dir(pkg, options)

                if pkg.kind_of?(Autobuild::CMake) || pkg.kind_of?(Autobuild::Autotools)
                    package_deb(pkg, options, options[:distributions].first)
                elsif pkg.kind_of?(Autobuild::Ruby)
                    package_ruby(pkg, options)
                elsif pkg.importer.kind_of?(Autobuild::ArchiveImporter) || pkg.kind_of?(Autobuild::ImporterPackage)
                    package_importer(pkg, options)
                else
                    raise ArgumentError, "Debian: Unsupported package type #{pkg.class} for #{pkg.name}"
                end
                if !options[:package_set_dir].nil?
                    osdeps_file = YAML.load_file(options[:package_set_dir] + "rock-osdeps.osdeps")
                    osdeps_file[pkg.name] = {'debian,ubuntu' => debian_name(pkg)}
                    File.open(options[:package_set_dir] + "rock-osdeps.osdeps", 'w+') {|f| f.write(osdeps_file.to_yaml) }
                end
            end

            # Create an osc package of an existing ruby package
            def package_ruby(pkg, options)
                Packager.info "Package Ruby: '#{pkg}' with options: #{options}"
                # update dependencies in any case, i.e. independant if package exists or not
                deps = dependencies(pkg)
                Dir.chdir(pkg.srcdir) do
                    begin
                        logname = "obs-#{pkg.name.sub("/","-")}" + "-" + Time.now.strftime("%Y%m%d-%H%M%S").to_s + ".log"
                        gem = FileList["pkg/*.gem"].first
                        if not gem
                            Packager.info "Debian: preparing gem generation in #{Dir.pwd}"

                            # Rake targets that should be tried for cleaning
                            gem_clean_alternatives = ['clean','dist:clean','clobber']
                            gem_clean_success = false
                            gem_clean_alternatives.each do |target|
                                if !system("rake #{target} > #{File.join(log_dir, logname)} 2> #{File.join(log_dir, logname)}")
                                    Packager.info "Debian: failed to clean package '#{pkg.name}' using target '#{target}'"
                                else
                                    Packager.info "Debian: succeeded to clean package '#{pkg.name}' using target '#{target}'"
                                    gem_clean_success = true
                                    break
                                end
                            end
                            if not gem_clean_success
                                Packager.warn "Debian: failed to cleanup ruby package '#{pkg.name}' -- continuing without cleanup"
                            end

                            Packager.info "Debian: ruby package Manifest.txt is being autogenerated"
                            if !system('find . -type f | grep -v .git/ | grep -v build/ | grep -v tmp/ | sed \'s/\.\///\' > Manifest.txt')
                                raise "Debian: failed to create an up to date Manifest.txt"
                            end
                            Packager.info "Debian: creating gem from package #{pkg.name} [#{File.join(log_dir, logname)}]"

                            gem_creation_alternatives = ['gem','dist:gem','build']
                            gem_creation_success = false
                            gem_creation_alternatives.each do |target|
                                if !system("rake #{target} >> #{File.join(log_dir, logname)} 2>> #{File.join(log_dir, logname)}")
                                    Packager.info "Debian: failed to create gem using target '#{target}'"
                                else
                                    Packager.info "Debian: succeeded to create gem using target '#{target}'"
                                    gem_creation_success = true
                                    break
                                end
                            end
                            if not gem_creation_success
                                raise "Debian: failed to create gem from RubyPackage #{pkg.name}"
                            end
                        end

                        gem = FileList["pkg/*.gem"].first

                        # Make the naming of the gem consistent with the naming schema of
                        # rock packages
                        #
                        # Make sure the gem has the fullname, e.g.
                        # tools-metaruby instead of just metaruby
                        Packager.info "Debian: '#{pkg.name}' -- basename: #{basename(pkg.name)} will be canonized to: #{canonize(pkg.name)}"
                        gem_rename = gem.sub(basename(pkg.name), canonize(pkg.name))
                        if gem != gem_rename
                            Packager.info "Debian: renaming #{gem} to #{gem_rename}"
                        end

                        Packager.debug "Debian: copy #{gem} to #{packaging_dir(pkg)}"
                        gem_final_path = File.join(packaging_dir(pkg), File.basename(gem_rename))
                        FileUtils.cp gem, gem_final_path

                        # Prepare injection of dependencies
                        options[:deps] = deps
                        convert_gem(gem_final_path, options)
                        # register gem with the correct naming schema
                        # to make sure dependency naming and gem naming are consistent
                        @ruby_rock_gems << debian_name(pkg)
                    rescue Exception => e
                        raise "Debian: failed to create gem from RubyPackage #{pkg.name} -- #{e.message}\n#{e.backtrace.join("\n")}"
                    end
                end
            end

            def package_deb(pkg, options, distribution)
                Packager.info "Package Deb: '#{pkg}' with options: #{options} and distribution: #{distribution}"
                Packager.info "Changing into packaging dir: #{packaging_dir(pkg)}"
                Dir.chdir(packaging_dir(pkg)) do
                    FileUtils.rm_rf File.join(pkg.srcdir, "debian")
                    FileUtils.rm_rf File.join(pkg.srcdir, "build")

                    sources_name = plain_versioned_name(pkg, distribution)
                    # First, generate the source tarball
                    tarball = "#{sources_name}.orig.tar.gz"

                    # Check first if actual source contains newer information than existing
                    # orig.tar.gz -- only then we create a new debian package
                    if package_updated?(pkg)

                        Packager.warn "Package: #{pkg.name} requires update #{pkg.srcdir}"

                        # Make sure that the tar files checksum remains the same, even when modification timestamp changes, 
                        # i.e. use gzip --no-name and set the initial date to the current day
                        #
                        # TODO: What if building over midnight -- prone to failure
                        date=`date %Y%M%d`
                        cmd_tar = "tar --mtime=#{date} --format=gnu --c --exclude .git --exclude .svn --exclude CVS --exclude debian --exclude build #{File.basename(pkg.srcdir)} | gzip --no-name > #{tarball} "
                        if !system(cmd_tar)
                            Packager.warn "Package: #{pkg.name} failed to create archive using command '#{cmd_tar}' -- pwd #{ENV['PWD']}"
                            raise RuntimeError, "Debian: #{pkg.name} failed to create archive using command '#{cmd_tar}' -- pwd #{ENV['PWD']}"
                        else
                            Packager.info "Package: #{pkg.name} successfully created archive using command '#{cmd_tar}' -- pwd #{ENV['PWD']}"
                        end

                        # Generate the debian directory
                        generate_debian_dir(pkg, pkg.srcdir, distribution)

                        # Commit local changes, e.g. check for
                        # control/urdfdom as an example
                        dpkg_commit_changes("local_build_changes", pkg.srcdir)

                        # Run dpkg-source
                        # Use the new tar ball as source
                        if !system("dpkg-source", "-I", "-b", pkg.srcdir)
                            Packager.warn "Package: #{pkg.name} failed to perform dpkg-source -- #{Dir.entries(pkg.srcdir)}"
                            raise RuntimeError, "Debian: #{pkg.name} failed to perform dpkg-source in #{pkg.srcdir}"
                        end
                        ["#{versioned_name(pkg, distribution)}.debian.tar.gz",
                         "#{plain_versioned_name(pkg, distribution)}.orig.tar.gz",
                         "#{versioned_name(pkg, distribution)}.dsc"]
                    else
                        # just to update the required gem property
                        dependencies(pkg)
                        Packager.info "Package: #{pkg.name} is up to date"
                    end
                    FileUtils.rm_rf( File.basename(pkg.srcdir) )
                end
            end

            def package_importer(pkg, options)
                Packager.info "Using package_importer for #{pkg.name}"
                distribution = max_one_distribution(options[:distributions])

                Dir.chdir(packaging_dir(pkg)) do

                    dir_name = versioned_name(pkg, distribution)
                    FileUtils.rm_rf File.join(pkg.srcdir, "debian")
                    FileUtils.rm_rf File.join(pkg.srcdir, "build")

                    # Generate a CMakeLists which installs every file
                    cmake = File.new(dir_name + "/CMakeLists.txt", "w+")
                    cmake.puts "cmake_minimum_required(VERSION 2.6)"
                    add_folder_to_cmake "#{Dir.pwd}/#{dir_name}", cmake, pkg.name
                    cmake.close

                    # First, generate the source tarball
                    sources_name = plain_versioned_name(pkg, distribution)
                    tarball = "#{dir_name}.orig.tar.gz"

                    # Check first if actual source contains newer information than existing
                    # orig.tar.gz -- only then we create a new debian package
                    if package_updated?(pkg)

                        Packager.warn "Package: #{pkg.name} requires update #{pkg.srcdir}"
                        cmd_tar = "tar czf #{tarball} --exclude .git --exclude .svn --exclude CVS --exclude debian --exclude build #{File.basename(pkg.srcdir)}"
                        if !system(cmd_tar)
                            Packager.warn "Package: on import #{pkg.name} failed to create archive using command '#{cmd_tar}' -- pwd #{ENV['PWD']}"
                            raise RuntimeError, "Debian: on import #{pkg.name} failed to create archive using command '#{cmd_tar}' -- pwd #{ENV['PWD']}"
                        else
                            Packager.info "Package: #{pkg.name} successfully created archive using command '#{cmd_tar}' -- pwd #{ENV['PWD']}"
                        end

                        # Generate the debian directory
                        generate_debian_dir(pkg, pkg.srcdir, distribution)

                        # Commit local changes, e.g. check for
                        # control/urdfdom as an example
                        dpkg_commit_changes("local_build_changes", pkg.srcdir)

                        # Run dpkg-source
                        # Use the new tar ball as source
                        if !system("dpkg-source", "-I", "-b", pkg.srcdir)
                            Packager.warn "Package: #{pkg.name} failed to perform dpkg-source: entries #{Dir.entries(pkg.srcdir)}"
                            raise RuntimeError, "Debian: #{pkg.name} failed to perform dpkg-source in #{pkg.srcdir}"
                        end
                        ["#{versioned_name(pkg, distribution)}.debian.tar.gz",
                         "#{plain_versioned_name(pkg, distribution)}.orig.tar.gz",
                         "#{versioned_name(pkg, distribution)}.dsc"]
                    else
                        # just to update the required gem property
                        dependencies(pkg)
                        Packager.info "Package: #{pkg.name} is up to date"
                    end
                end
            end

            # For importer-packages we need to add every file in the deb-package, for that we "install" every file with CMake
            # This method adds an install-line of every file (including subdirectories) of a file into the given cmake-file
            def add_folder_to_cmake(base_dir, cmake, destination, folder = ".")
                Dir.foreach("#{base_dir}/#{folder}") do |file|
                    next if file.to_s == "." or file.to_s == ".." or file.to_s.start_with? "."
                    if File.directory? "#{base_dir}/#{folder}/#{file}"
                        # create the potentially empty folder. If the folder is not empty this is useless, but empty folders would not be generated
                        cmake.puts "install(DIRECTORY #{folder}/#{file} DESTINATION share/rock/#{destination}/#{folder} FILES_MATCHING PATTERN .* EXCLUDE)"
                        add_folder_to_cmake base_dir, cmake, destination, "#{folder}/#{file}"
                    else
                        cmake.puts "install(FILES #{folder}/#{file} DESTINATION share/rock/#{destination}/#{folder})"
                    end
                end
            end

            # We create a diff between the existing orig.tar.gz and the source directory
            # to identify if there have been any updates
            #
            # Using 'diff' allows us to apply this test to all kind of packages
            def package_updated?(pkg)
                # Find an existing orig.tar.gz in the build directory
                # ignoring the current version-timestamp
                orig_file_name = Dir.glob("#{debian_name(pkg)}*.orig.tar.gz")
                if orig_file_name.empty?
                    Packager.info "No filename found for #{debian_name(pkg)} -- package requires update #{Dir.entries('.')}"
                    return true
                elsif orig_file_name.size > 1
                    Packager.warn "Multiple version of package #{debian_name(pkg)} in #{Dir.pwd} -- you have to fix this first"
                else
                    orig_file_name = orig_file_name.first
                end

                # Create a local copy/backup of the current orig.tar.gz in .obs_package
                # and extract it there -- compare the actual source package
                FileUtils.cp(orig_file_name, local_tmp_dir)
                Dir.chdir(local_tmp_dir) do
                    `tar xzf #{orig_file_name}`
                    base_name = orig_file_name.sub(".orig.tar.gz","")
                    Dir.chdir(base_name) do
                        diff_name = File.join(local_tmp_dir, "#{orig_file_name}.diff")
                        `diff -urN --exclude .git --exclude .svn --exclude CVS --exclude debian --exclude build #{pkg.srcdir} . > #{diff_name}`
                        Packager.info "Package: '#{pkg.name}' checking diff file '#{diff_name}'"
                        if File.open(diff_name).lines.any?
                            return true
                        end
                    end
                end
                return false
            end

            # Prepare the build directory, i.e. cleanup and obsolete file
            def prepare
                if not File.exists?(build_dir)
                    FileUtils.mkdir_p build_dir
                end
                cleanup
            end

            # Cleanup an existing local tmp folder in the build dir
            def cleanup
                tmpdir = File.join(build_dir,local_tmp_dir)
                if File.exists?(tmpdir)
                    FileUtils.rm_rf(tmpdir)
                end
            end

            def file_suffix_patterns
                [".dsc", ".orig.tar.gz", ".debian.tar.gz"]
            end

            def system(*args)
                Kernel.system(*args)
            end

            # Convert all gems that are required
            # by package build with the debian packager
            def convert_gems(options = Hash.new)
                Packager.info "Convert gems: with options #{options}"

                options, unknown_options = Kernel.filter_options options,
                    :force_update => false,
                    :patch_dir => nil,
                    :distributions => []

                distribution = max_one_distribution(options[:distributions])

                if unknown_options.size > 0
                    Packager.warn "Autoproj::Packaging Unknown options provided to convert gems: #{unknown_options}"
                end

                # We use gem2deb for the job of converting the gems
                # However, since we require some gems to be patched we split the process into the
                # individual step
                # This allows to add an overlay (patch) to be added to the final directory -- which
                # requires to be commited via dpkg-source --commit
                @ruby_gems.each do |gem_name, version|
                    gem_dir_name = debian_ruby_name(gem_name)

                    if options[:force_update]
                        dirname = File.join(build_dir, gem_dir_name)
                        if File.directory?(dirname)
                            Packager.info "Debian Gem: rebuild requested -- removing #{dirname}"
                            FileUtils.rm_rf(dirname)
                        end
                    end
                    # Assuming if the .gem file has been download we do not need to update
                    if options[:force_update] or not Dir.glob("#{gem_dir_name}/#{gem_name}*.gem").size > 0
                        Packager.debug "Converting gem: '#{gem_name}' to debian source package"
                        if not File.directory?(gem_dir_name)
                            FileUtils.mkdir gem_dir_name
                        end

                        Dir.chdir(gem_dir_name) do
                            if version
                                `gem fetch #{gem_name} --version '#{version}'`
                            else
                                `gem fetch #{gem_name}`
                            end
                        end
                        gem_file_name = Dir.glob("#{gem_dir_name}/#{gem_name}*.gem").first
                        convert_gem(gem_file_name, options)
                    else
                        Packager.info "gem: #{gem_name} up to date"
                    end
                end
            end

            # When providing the path to a gem file converts the gem into
            # a debian package (files will be residing in the same folder
            # as the gem)
            #
            # When provided a patch directory with the name of the gem,
            # e.g. hoe, nokogiri, utilrb
            # the corresponding files will be copy into the built package during
            # the gem building process
            def convert_gem(gem_path, options = Hash.new)
                Packager.debug "Convert gem: '#{gem_path}' with options: #{options}"

                options, unknown_options = Kernel.filter_options options,
                    :patch_dir => nil,
                    :deps => [[],[]],
                    :distributions => []

                distribution = max_one_distribution(options[:distributions])

                Dir.chdir(File.dirname(gem_path)) do
                    gem_file_name = File.basename(gem_path)
                    gem_versioned_name = gem_file_name.sub("\.gem","")

                    # Dealing with _ in original file name, since gem2deb
                    # will debianize it
                    if gem_versioned_name =~ /(.*)([-_][0-9\.-]*)/
                        base_name = $1
                        version_suffix = $2
                        gem_versioned_name = base_name.gsub("_","-") + version_suffix
                    else
                        raise ArgumentError, "Converting gem: unknown formatting"
                    end

                    Packager.info "Converting gem: #{gem_versioned_name} in #{Dir.pwd}"
                    # Convert .gem to .tar.gz
                    if not system("gem2tgz #{gem_file_name}")
                        raise RuntimeError, "Converting gem: '#{gem_path}' failed -- gem2tgz failed"
                    end

                    # Create ruby-<name>-<version> folder including debian/ folder
                    # from .tar.gz
                    #`dh-make-ruby --ruby-versions "ruby1.9.1" #{gem_versioned_name}.tar.gz`
                    #
                    # By default generate for all ruby versions
                    `dh-make-ruby #{gem_versioned_name}.tar.gz`

                    debian_ruby_name = debian_ruby_name(gem_versioned_name)# + '~' + distribution
                    Packager.info "Debian ruby name: #{debian_ruby_name}"


                    # Check if patching is needed
                    # To allow patching we need to split `gem2deb -S #{gem_name}`
                    # into its substeps
                    Dir.chdir(debian_ruby_name) do

                        # Only if a patch directory is given then update
                        if patch_dir = options[:patch_dir]
                            gem_name = ""
                            if gem_versioned_name =~ /(.*)[-_][0-9\.]*/
                                gem_name = $1
                            end

                            gem_patch_dir = File.join(patch_dir, gem_name)
                            if File.directory?(gem_patch_dir)
                                Packager.warn "Applying overlay (patch) to: gem '#{gem_name}'"
                                FileUtils.cp_r("#{gem_patch_dir}/.", ".")

                                # We need to commit if original files have been modified
                                # so add a commit
                                orig_files = Dir["#{gem_patch_dir}/**"].reject { |f| f["#{gem_patch_dir}/debian/"] }
                                if orig_files.size > 0
                                    dpkg_commit_changes("ocl_autopackaging_overlay")
                                end
                            else
                                Packager.warn "No patch dir: #{gem_patch_dir}"
                            end
                        end

                        # Injecting dependencies into debian/control
                        # Since we do not differentiate between build and runtime dependencies
                        # at Rock level -- we add them to both
                        #
                        # Enforces to have all dependencies available when building the packages
                        # at the build server
                        deps = options[:deps].flatten.uniq
                        # Filter ruby versions out -- we assume chroot has installed all
                        # ruby versions
                        deps = deps.select do |name|
                            name !~ /^ruby[0-9][0-9.]*/
                        end
                        deps << "dh-autoreconf"
                        if not deps.empty?
                            Packager.info "#{debian_ruby_name}: injecting gem dependencies: #{deps.join(",")}"
                            `sed -i "s#^\\(^Build-Depends: .*\\)#\\1, #{deps.join(",")}#" debian/control`
                            `sed -i "s#^\\(^Depends: .*\\)#\\1, #{deps.join(",")}#" debian/control`

                            dpkg_commit_changes("ocl_extra_dependencies")
                        end

                        Packager.info "Relaxing version requirement for: debhelper and gem2deb"
                        # Relaxing the required gem2deb version to allow for for multiplatform support
                        `sed -i "s#^\\(^Build-Depends: .*\\)gem2deb (>= [0-9\.~]\\+)\\(, .*\\)#\\1 gem2deb\\2#g" debian/control`
                        `sed -i "s#^\\(^Build-Depends: .*\\)debhelper (>= [0-9\.~]\\+)\\(, .*\\)#\\1 debhelper\\2#g" debian/control`
                        dpkg_commit_changes("relax_version_requirements")


                        # Ignore all ruby test results when the binary package is build (on the build server)
                        # via:
                        # dpkg-buildpackage -us -uc
                        #
                        # Thus uncommented line of
                        # export DH_RUBY_IGNORE_TESTS=all
                        Packager.debug "Disabling ruby test result evaluation"
                        `sed -i 's/#\\(export DH_RUBY_IGNORE_TESTS=all\\)/\\1/' debian/rules`
                        `sed -i "s#Architecture: all#Architecture: any#" debian/control`


                        dpkg_commit_changes("any-architecture")
                        # Any change of the version in the changelog file will directly affect the
                        # naming of the *.debian.tar.gz and the *.dsc file
                        #
                        # Subsequently also the debian package will be (re)named according to this
                        # version string.
                        #
                        if distribution
                            # Changelog entry initially, e.g.,
                            # ruby-activesupport (4.2.3-1) UNRELEASED; urgency=medium
                            #
                            # after
                            # ruby-activesupport (4.2.3-1~trusty) UNRELEASED; urgency=medium
                            if `sed -i 's#\(\\([0-9][0-9\.-]\\+\\)\)#\(\\1~#{distribution}\)#' debian/changelog`
                                Packager.info "Injecting distribution info: '~#{distribution}' into debian/changelog"
                            else
                                raise RuntimeError, "Failed to inject distribution infor into debian/changelog"
                            end
                        end
                    end


                    # Build only a debian source package -- do not compile binary package
                    Packager.info "Building debian source package: #{debian_ruby_name}"
                    result = `dpkg-source -I -b #{debian_ruby_name}`
                    Packager.info "Resulting debian files: #{Dir.glob("**")} in #{Dir.pwd}"
                end
            end #end def

            def self.installable_ruby_versions
                version_file = File.join(local_tmp_dir,"ruby_versions")
                systems("apt-cache search ruby | grep -e '^ruby[0-9][0-9.]*-dev' | cut -d' ' -f1 > #{version_file}")
                ruby_versions = []
                File.open(version_file,"r") do |file|
                    ruby_versions = file.read.split("\n")
                end
                ruby_versions = ruby_versions.collect do |version|
                    version.gsub(/-dev/,"")
                end
                ruby_versions
            end
        end #end Debian
    end
end

