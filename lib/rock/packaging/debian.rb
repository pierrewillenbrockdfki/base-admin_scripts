require 'find'
require 'tmpdir'
require 'utilrb'
require 'timeout'
require 'time'
require 'rexml/document'
require_relative 'debiancontrol'

module Autoproj
    module Packaging
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
            DEPWHITELIST = ["debhelper","gem2deb","ruby","ruby-rspec"]

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
            attr_accessor :rock_base_install_directory
            attr_accessor :rock_release_name

            # List of alternative rake target names to clean a gem
            attr_accessor :gem_clean_alternatives
            # List of alternative rake target names to create a gem
            attr_accessor :gem_creation_alternatives

            attr_reader :target_platform
            attr_reader :rock_release_platform
            attr_reader :rock_release_hierarchy

            attr_accessor :package_set_order

            def initialize(options = Hash.new)
                super()

                options, unknown_options = Kernel.filter_options options,
                    :distribution => TargetPlatform.autodetect_linux_distribution_release,
                    :architecture => TargetPlatform.autodetect_dpkg_architecture

                @ruby_gems = Array.new
                @ruby_rock_gems = Array.new
                @osdeps = Array.new
                @package_aliases = Hash.new
                @debian_version = Hash.new
                @rock_base_install_directory = "/opt/rock"

                # Rake targets that will be used to clean and create
                # gems
                @gem_clean_alternatives = ['clean','dist:clean','clobber']
                @gem_creation_alternatives = ['gem','dist:gem','build']
                @target_platform = TargetPlatform.new(options[:distribution], options[:architecture])

                # Package set order
                @package_set_order = []

                rock_release_name = "release-#{Time.now.strftime("%y.%m")}"

                if not File.exists?(local_tmp_dir)
                    FileUtils.mkdir_p local_tmp_dir
                end

                if not File.exists?(log_dir)
                    FileUtils.mkdir_p log_dir
                end
            end

            # Canonize that name -- downcase and replace _ with -
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

            # Add a package alias, e.g. for rtt --> tools/rtt
            def add_package_alias(pkg_name, pkg_alias)
                @package_aliases[pkg_name] = pkg_alias
            end

            # The debian name of a package -- either
            # rock[-<release-name>]-<canonized-package-name>
            # or for ruby packages
            # ruby[-<release-name>]-<canonized-package-name>
            # and the release-name can be avoided by setting
            # with_rock_release_prefix to false
            #
            def debian_name(pkg, with_rock_release_prefix = true)
                if pkg.kind_of?(String)
                    raise ArgumentError, "method debian_name expects a autobuild pkg as argument, got: #{pkg.class} '#{pkg}'"
                end
                name = pkg.name

                if @package_aliases.has_key?(name)
                    name = @package_aliases[name]
                end

                if pkg.kind_of?(Autobuild::Ruby)
                    debian_ruby_name(name, with_rock_release_prefix)
                else
                    if with_rock_release_prefix
                        rock_release_prefix + canonize(name)
                    else
                        "rock-" + canonize(name)
                    end
                end
            end

            # Get the current rock-release-based prefix for rock packages
            def rock_release_prefix(release_name = nil)
                release_name ||= rock_release_name
                "rock-#{release_name}-"
            end

            # Get the current rock-release-based prefix for rock-(ruby) packages
            def rock_ruby_release_prefix(release_name = nil)
                rock_release_prefix(release_name) + "ruby-"
            end

            def debian_ruby_name(name, with_rock_release_prefix = true, release_name = nil)
                if with_rock_release_prefix
                    rock_ruby_release_prefix(release_name) + canonize(name)
                else
                    "ruby-" + canonize(name)
                end
            end

            def debian_version(pkg, distribution, revision = "1")
                if !@debian_version.has_key?(pkg.name)
                    if pkg.description.nil?
                       v = "0"
                    else
                        if !pkg.description.version
                           v = "0"
                        else
                           v = pkg.description.version
                        end
                    end
                    @debian_version[pkg.name] = v + "." + latest_commit_time(pkg).strftime("%Y%m%d") + "-" + revision
                    if distribution
                        @debian_version[pkg.name] += '~' + distribution
                    end
                end
                @debian_version[pkg.name]
            end

            # Extract the latest commit time for given importers
            # return a Time object
            def latest_commit_time(pkg)
                importer = pkg.importer
                if importer.kind_of?(Autobuild::Git)
                    git_version(pkg)
                elsif importer.kind_of?(Autobuild::SVN)
                    svn_version(pkg)
                elsif importer.kind_of?(Autobuild::ArchiveImporter) || importer.kind_of?(Autobuild::ImporterPackage)
                    archive_version(pkg)
                else
                    Packager.warn "No version extraction yet implemented for importer type: #{importer.class} -- using current time for version string"
                    Time.now
                end
            end

            def git_version(pkg)
                time_of_last_commit=pkg.importer.run_git_bare(pkg, 'log', '--encoding=UTF-8','--date=iso',"--pretty=format:'%cd'","-1").first
                Time.parse(time_of_last_commit.strip)
            end

            def svn_version(pkg)
                #["------------------------------------------------------------------------",
                # "r21 | anauthor | 2012-10-01 13:46:46 +0200 (Mo, 01. Okt 2012) | 1 Zeile",
                #  "",
                #   "some comment",
                #    "------------------------------------------------------------------------"]
                #
                svn_log = pkg.importer.run_svn(pkg, 'log', "-l 1", "--xml")
                svn_log = REXML::Document.new(svn_log.join("\n"))
                svn_log.elements.each('//log/logentry/date') do |d|
                    time_of_last_commit = Time.parse(d.text)
                end
            end

            def archive_version(pkg)
                File.lstat(pkg.importer.cachefile).mtime
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

            def plain_dir_name(pkg, distribution)
                plain_versioned_name(pkg, distribution)
            end

            def packaging_dir(pkg)
                pkg_name = pkg
                if !pkg.kind_of?(String)
                    pkg_name = debian_name(pkg)
                end
                File.join(@build_dir, pkg_name, target_platform.to_s.gsub("/","-"))
            end

            def rock_install_directory
                File.join(rock_base_install_directory, rock_release_name)
            end

            def package_by_name(package_name)
                Autoproj.manifest.package(package_name).autobuild
            end

            def rock_release_name=(name)
                @rock_release_name = name
                @rock_release_platform = TargetPlatform.new(name, target_platform.architecture)
                @rock_release_hierarchy = [name]
                if Config.rock_releases.has_key?(name)
                    release_hierarchy = Config.rock_releases[name][:depends_on].select do |release_name|
                        TargetPlatform.isRock(release_name)
                    end
                    # Add the actual release name as first
                    @rock_release_hierarchy += release_hierarchy
                end
            end


            # Compute all packages that are require and their corresponding
            # reverse dependencies
            # return [Hash<package_name, reverse_dependencies>]
            def reverse_dependencies(selection)
                Packager.info ("#{selection.size} packages selected")
                Packager.debug "Selection: #{selection}}"
                orig_selection = selection.clone
                reverse_dependencies = Hash.new

                all_packages = Set.new
                all_packages.merge(selection)
                while true
                    all_packages_refresh = all_packages.dup
                    all_packages.each do |pkg_name|
                        if @package_aliases.has_key?(pkg_name)
                            pkg_name = @package_aliases[pkg_name]
                        end

                        begin
                            pkg_manifest = Autoproj.manifest.load_package_manifest(pkg_name)
                        rescue Exception => e
                            raise RuntimeError, "Autoproj::Packaging::Debian: failed to load manifest for '#{pkg_name}' -- #{e}"
                        end

                        pkg = pkg_manifest.package

                        pkg.resolve_optional_dependencies
                        reverse_dependencies[pkg.name] = pkg.dependencies.dup
                        Packager.debug "deps: #{pkg.name} --> #{pkg.dependencies}"
                        all_packages_refresh.merge(pkg.dependencies)
                    end

                    if all_packages.size == all_packages_refresh.size
                        # nothing changed, so converged
                        break
                    else
                        all_packages = all_packages_refresh
                    end
                end
                Packager.info "all packages: #{all_packages.to_a}"
                Packager.info "reverse deps: #{reverse_dependencies}"

                reverse_dependencies
            end

            # Compute all required packages from a given selection
            # including the dependencies
            #
            # The selection is a list of package names
            #
            # The order of the resulting package list is sorted
            # accounting for interdependencies among packages
            def all_required_rock_packages(selection)
                reverse_dependencies = reverse_dependencies(selection)
                sort_packages(reverse_dependencies)
            end

            def sort_packages(reverse_dependencies_hash)
                # input is a hash, but we require a sorted list
                # to deal with package set order, so we convert

                reverse_dependencies = Array.new
                if !package_set_order.empty?
                    sorted_dependencies = Array.new
                    sorted_pkgs = sort_by_package_sets(reverse_dependencies_hash.keys, package_set_order)
                    sorted_pkgs.each do |pkg_name|
                       pkg_dependencies = reverse_dependencies_hash[pkg_name]
                       sorted_pkg_dependencies = sort_by_package_sets(pkg_dependencies, package_set_order)
                       sorted_dependencies << [ pkg_name, sorted_pkg_dependencies ]
                    end
                    reverse_dependencies = sorted_dependencies
                else
                    reverse_dependencies_hash.each do |k,v|
                        reverse_dependencies << [k,v]
                    end
                end

                all_required_packages = Array.new
                resolve_packages = []
                while true
                    if resolve_packages.empty?
                        if reverse_dependencies.empty?
                            break
                        else
                            # Pick the entries name
                            resolve_packages = [ reverse_dependencies.first.first ]
                        end
                    end

                    # Contains the name of all handled packages
                    handled_packages = Array.new
                    resolve_packages.each do |pkg_name|
                        name, dependencies = reverse_dependencies.find { |p| p.first == pkg_name }
                        if dependencies.empty?
                            handled_packages << pkg_name
                            pkg = Autoproj.manifest.package(pkg_name).autobuild
                            all_required_packages << pkg
                        else
                            resolve_packages += dependencies
                            resolve_packages.uniq!
                        end
                    end

                    handled_packages.each do |pkg_name|
                        resolve_packages.delete(pkg_name)
                        reverse_dependencies.delete_if { |dep_name, _| dep_name == pkg_name }
                    end

                    reverse_dependencies.map! do |pkg,dependencies|
                        dependencies.reject! { |x| handled_packages.include? x }
                        [pkg, dependencies]
                    end

                    Packager.debug "Handled: #{handled_packages}"
                    Packager.debug "Remaining: #{reverse_dependencies}"
                    if handled_packages.empty? && !resolve_packages
                        Packager.warn "Unhandled dependencies: #{resolve_packages}"
                    end
                end

                if rock_release_name
                    all_required_packages = all_required_packages.select do |pkg|
                        pkg_name = debian_name(pkg, true || with_prefix)
                        !rock_release_platform.ancestorContains(pkg_name)
                    end
                end
                all_required_packages
            end

            # Update the automatically generated osdeps list for a given
            # package
            def update_osdeps_lists(pkg, osdeps_files_dir)
                Packager.info "Update osdeps lists in #{osdeps_files_dir} for #{pkg}"
                if !File.exists?(osdeps_files_dir)
                    Packager.debug "Creating #{osdeps_files_dir}"
                    FileUtils.mkdir_p osdeps_files_dir
                else
                    Packager.debug "#{osdeps_files_dir} already exists"
                end

                Dir.chdir(osdeps_files_dir) do
                    Packaging::Config.active_configurations.each do |release,arch|
                        selected_platform = TargetPlatform.new(release, arch)
                        file = File.absolute_path("rock-osdeps.osdeps-#{rock_release_name}-#{arch}")
                        update_osdeps_list(pkg.dup, file, selected_platform)
                    end
                end
            end

            def update_osdeps_list(pkg, file, selected_platform)
                Packager.info "Update osdeps list for: #{selected_platform} -- in file #{file}"

                list = Hash.new
                if File.exist? file
                    Packager.info("Packagelist #{file} already exists: reloading")
                    list = YAML.load_file(file)
                end

                pkg_name = nil
                dependency_name = nil
                if pkg.is_a? String
                    # Handling of ruby and other gems
                    pkg_name = pkg
                    release_name, is_osdep = native_dependency_name(pkg_name, selected_platform)
                    Packager.debug "Native dependency of ruby package: '#{pkg_name}' -- #{release_name}, is available as osdep: #{is_osdep}"
                    if is_osdep
                        dependency_name = release_name
                    else
                        dependency_name = debian_ruby_name(pkg_name)
                    end
                else
                    pkg_name = pkg.name
                    # Handling of rock packages
                    dependency_name = debian_name(pkg)
                end

                # Get the operating system label
                types, labels = Config.linux_distribution_releases[selected_platform.distribution_release_name]
                types_string = types.join(",")
                labels_string = labels.join(",")

                Packager.debug "Existing definition: #{list[pkg_name]}"
                pkg_definition = list[pkg_name] || Hash.new
                distributions = pkg_definition[types_string] || Hash.new
                distributions[labels_string] = dependency_name
                pkg_definition[types_string] = distributions

                list[pkg_name] = pkg_definition
                Packager.debug "New definition: #{list[pkg_name]}"

                Packager.debug "Updating osdeps file: #{file} with #{pkg_name} -- #{pkg_definition}"
                File.open(file, 'w') {|f| f.write list.to_yaml }
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

            # Get all required packages that come with a given selection of packages
            # including the dependencies of ruby gems
            #
            # This requires the current installation to be complete since
            # `gem dependency <gem-name>` has been selected to provide the information
            # of ruby dependencies
            def all_required_packages(selection, with_rock_release_prefix = false)
                all_packages = all_required_rock_packages(selection)
                rock_packages = all_packages.map{ |pkg| debian_name(pkg, with_rock_release_prefix) }

                gems = Array.new
                gem_versions = Hash.new

                # Make sure to account for extra packages
                @ruby_gems.each do |name, version|
                    gems << name
                    gem_versions[name] ||= Array.new
                    gem_versions[name] << version
                end

                # Add the ruby requirements for the current rock selection
                all_packages.each do |pkg|
                    pkg = package_by_name(pkg.name)
                    deps = dependencies(pkg, with_rock_release_prefix)
                    deps[:nonnative].each do |dep, version|
                        gem_versions[dep] ||= Array.new
                        if version
                            gem_versions[dep] << version
                        end
                    end
                end

                gem_version_requirements = gem_versions.dup
                gem_dependencies = GemDependencies.resolve_all(gem_versions)
                gem_dependencies.each do |name, deps|
                    if deps
                        deps.each do |dep_name, dep_versions|
                            gem_version_requirements[dep_name] ||= Array.new
                            gem_version_requirements[dep_name] = (gem_version_requirements[dep_name] + dep_versions).uniq
                        end
                    end
                end
                exact_version_list = GemDependencies.gem_exact_versions(gem_version_requirements)
                sorted_gem_list = GemDependencies.sort_by_dependency(gem_dependencies).uniq

                # Filter all packages that are available
                if rock_release_name
                    rock_release_platform = TargetPlatform.new(rock_release_name, target_platform.architecture)
                    sorted_gem_list = sorted_gem_list.select do |gem|
                        with_prefix = true
                        pkg_ruby_name = debian_ruby_name(gem, !with_prefix)
                        pkg_prefixed_name = debian_ruby_name(gem, with_prefix)

                        !( rock_release_platform.ancestorContains(gem) ||
                          rock_release_platform.ancestorContains(pkg_ruby_name) ||
                          rock_release_platform.ancestorContains(pkg_prefixed_name))
                    end
                end
                {:packages => all_packages, :gems => sorted_gem_list, :gem_versions => exact_version_list }
            end

            # Compute all recursive dependencies for a given package
            #
            # return the complete list of dependencies required for a package with the given name
            def recursive_dependencies(pkg_name)
                all_required_pkgs = all_required_packages([pkg_name])
                all_recursive_deps = {:rock => [], :osdeps => [], :nonnative => []}
                all_required_pkgs[:packages].each do |p|
                    pdep = dependencies(p)
                    pdep.keys.each do |k|
                        all_recursive_deps[k].concat pdep[k]
                    end
                end
                all_recursive_deps.each_value { |a| a.uniq! }

                if !all_recursive_deps[:nonnative].empty?
                    all_recursive_deps[:nonnative] = GemDependencies::resolve_all(all_recursive_deps[:nonnative])
                end
                recursive_deps = all_recursive_deps.values.flatten.uniq
            end

            # Compute dependencies of this package
            # Returns [:rock => rock_packages, :osdeps => osdeps_packages, :nonnative => nonnative_packages ]
            def dependencies(pkg, with_rock_release_prefix = true)
                pkg = package_by_name(pkg.name)

                pkg.resolve_optional_dependencies
                this_rock_release = TargetPlatform.new(rock_release_name, target_platform.architecture)
                deps_rock_packages = pkg.dependencies.map do |dep_name|
                    debian_name = debian_name( package_by_name(dep_name), with_rock_release_prefix)
                    this_rock_release.packageReleaseName(debian_name)
                end.sort

                Packager.info "'#{pkg.name}' with rock package dependencies: '#{deps_rock_packages}' -- #{pkg.dependencies} on '#{Autoproj::OSDependencies.operating_system}'"

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
                Packager.info "'#{pkg.name}' with osdeps dependencies: '#{deps_osdeps_packages}'"

                # Update global list
                @osdeps += deps_osdeps_packages

                non_native_handlers = pkg_osdeps.collect do |handler, pkg_list|
                    if handler != native_package_manager
                        [handler, pkg_list]
                    end
                end.compact

                non_native_dependencies = Set.new
                non_native_handlers.each do |pkg_handler, pkg_list|
                    # Convert native ruby gems package names to rock-xxx
                    if pkg_handler.kind_of?(Autoproj::PackageManagers::GemManager)
                        pkg_list.each do |name,version|
                            @ruby_gems << [name,version]
                            non_native_dependencies << [name, version]
                        end
                    else
                        raise ArgumentError, "cannot package #{pkg.name} as it has non-native dependencies (#{pkg_list}) -- #{pkg_handler.class} #{pkg_handler}"
                    end
                end
                Packager.info "#{pkg.name}' with non native dependencies: #{non_native_dependencies.to_a}"

                # Remove duplicates
                @osdeps.uniq!
                @ruby_gems.uniq!

                if target_platform.distribution_release_name
                    # CASTXML vs. GCCXML in typelib
                    if pkg.name =~ /typelib/
                        # add/remove the optional dependencies on the
                        # rock-package depending on the target platform
                        # there are typelib versions with and without the
                        # optional depends. we know which platform requires
                        # a particular dependency.
                        if ["xenial"].include?(target_platform.distribution_release_name)
                            deps_rock_packages.delete(rock_release_prefix + "castxml")
                            deps_rock_packages.delete(rock_release_prefix + "gccxml")
                            deps_osdeps_packages.push("castxml")
                        else
                            #todo: these need to checked on the other platforms
                            deps_rock_packages.delete(rock_release_prefix + "castxml")
                            deps_rock_packages.delete(rock_release_prefix + "gccxml")
                            deps_osdeps_packages.push("gccxml")
                        end
                    end
                    Packager.info "'#{pkg.name}' with (available) rock package dependencies: '#{deps_rock_packages}' -- #{pkg.dependencies}"

                    # Filter out optional packages, e.g. llvm and clang for all platforms where not explicitly available
                    deps_osdeps_packages = deps_osdeps_packages.select do |name|
                        result = true
                        Packaging::Config.packages_optional.each do |pkg_name|
                            regex = Regexp.new(pkg_name)
                            if regex.match(name)
                                result = target_platform.contains(name)
                            end
                        end
                        result
                    end
                    Packager.info "'#{pkg.name}' with (available) osdeps dependencies: '#{deps_osdeps_packages}'"

                    # Filter ruby versions out -- we assume chroot has installed all
                    # ruby versions
                    #
                    # This is a workaround, since the information about required packages
                    # comes from the build server platform and might not correspond
                    # with the target platform
                    #
                    # Right approach: bootstrap within chroot and generate source packages
                    # in the chroot
                    #deps_osdeps_packages = deps[:osdeps].select do |name|
                    deps_osdeps_packages = deps_osdeps_packages.select do |name|
                        name !~ /^ruby[0-9][0-9.]*/
                    end

                    # Prefer package of the OS for gems if they are available there
                    #deps_nonnative_packages = deps[:nonnative].map do |name, version|
                    non_native_dependencies = non_native_dependencies.map do |name, version|
                        dep_name,is_osdep = native_dependency_name(name)
                        # if with_rock_release_prefix is given all packages 'have to be'
                        # os dependencies, otherwise it triggers further resolution of nonnative packages
                        # which cannot exist (in resolve_all)
                        if is_osdep || with_rock_release_prefix
                            deps_osdeps_packages << dep_name
                            nil
                        else
                            name
                        end
                    end.compact
                end

                # Return rock packages, osdeps and non native deps (here gems)
                {:rock => deps_rock_packages, :osdeps => deps_osdeps_packages, :nonnative => non_native_dependencies }
            end

            # Check if the plain package name exists in the target (ubuntu/debian) distribution or any ancestor (rock) distributions
            # and identify the correct package name
            # return [String,bool] Name of the dependency and whether this is an os dependency or not
            def native_dependency_name(name, selected_platform = nil)
                platforms = Set.new
                if !selected_platform
                    selected_platform = target_platform
                end
                platforms << selected_platform

                # Identify this rock release and its ancestors
                this_rock_release = TargetPlatform.new(rock_release_name, selected_platform.architecture)
                this_rock_release.ancestors.each do |ancestor|
                    platforms << TargetPlatform.new(ancestor, selected_platform.architecture)
                end

                # Check for 'plain' name, the 'unprefixed' name and for the 'release' name
                platforms.each do |platform|
                    if platform.contains(name)
                        return [name, true]
                    elsif platform.contains(debian_ruby_name(name, false))
                        return [debian_ruby_name(name, false), true]
                    else
                        pkg_name = debian_ruby_name(name, true, platform.distribution_release_name)
                        if platform.contains(pkg_name)
                            return [pkg_name, true]
                        end
                    end
                end
                # Return the 'release' name, since no other source provides this package
                [debian_ruby_name(name, true), false]
            end

            def generate_debian_dir(pkg, dir, options)
                options, unknown_options = Kernel.filter_options options,
                    :distribution => nil

                distribution = options[:distribution]

                existing_debian_dir = File.join(pkg.srcdir,"debian")
                template_dir =
                    if File.directory?(existing_debian_dir)
                        existing_debian_dir
                    else
                        TEMPLATES
                    end

                dir = File.join(dir, "debian")
                FileUtils.mkdir_p dir
                package = pkg
                debian_name = debian_name(pkg)
                debian_version = debian_version(pkg, distribution)
                versioned_name = versioned_name(pkg, distribution)

                with_rock_prefix = true
                deps = dependencies(pkg, with_rock_prefix)
                deps_rock_packages = deps[:rock]
                deps_osdeps_packages = deps[:osdeps]
                deps_nonnative_packages = deps[:nonnative].to_a.flatten.compact

                Packager.info "Required OS Deps: #{deps_osdeps_packages}"
                Packager.info "Required Nonnative Deps: #{deps_nonnative_packages}"

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

            # A tar gzip version that reproduces
            # same checksums on the same day when file content does not change
            #
            # Required to package orig.tar.gz
            def tar_gzip(archive, tarfile, pkg_time, distribution = nil)

                # Make sure no distribution information leaks into the package
                if distribution and archive =~ /~#{distribution}/
                    archive_plain_name = archive.gsub(/~#{distribution}/,"")
                    FileUtils.cp_r archive, archive_plain_name
                else
                    archive_plain_name = archive
                end


                Packager.info "Tar archive: #{archive_plain_name} into #{tarfile}"
                # Make sure that the tar files checksum remains the same by
                # overriding the modification timestamps in the tarball with
                # some external source timestamp and using gzip --no-name
                #
                # exclude hidden files an directories
                mtime = pkg_time.iso8601()
                cmd_tar = "tar --mtime='#{mtime}' --format=gnu -c --exclude '.*' --exclude CVS --exclude debian --exclude build #{archive_plain_name} | gzip --no-name > #{tarfile}"

                if system(cmd_tar)
                    Packager.info "Package: successfully created archive using command '#{cmd_tar}' -- pwd #{Dir.pwd} -- #{Dir.glob("**")}"
                    checksum = `sha256sum #{tarfile}`
                    Packager.info "Package: sha256sum: #{checksum}"
                    return true
                else
                    Packager.info "Package: failed to create archive using command '#{cmd_tar}' -- pwd #{Dir.pwd}"
                    return false
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
                    :distribution => nil, # allow to override global settings
                    :architecture => nil

                if options[:force_update]
                    dirname = packaging_dir(pkg)
                    if File.directory?(dirname)
                        Packager.info "Debian: rebuild requested -- removing #{dirname}"
                        FileUtils.rm_rf(dirname)
                    end
                end

                options[:distribution] ||= target_platform.distribution_release_name
                options[:architecture] ||= target_platform.architecture
                options[:packaging_dir] = packaging_dir(pkg)

                pkg_commit_time = latest_commit_time(pkg);
                pkg = prepare_source_dir(pkg, options)

                if pkg.kind_of?(Autobuild::CMake) || pkg.kind_of?(Autobuild::Autotools)
                    package_deb(pkg, pkg_commit_time, options)
                elsif pkg.kind_of?(Autobuild::Ruby)
                    package_ruby(pkg, pkg_commit_time, options)
                elsif pkg.importer.kind_of?(Autobuild::ArchiveImporter) || pkg.kind_of?(Autobuild::ImporterPackage)
                    package_importer(pkg, pkg_commit_time, options)
                else
                    raise ArgumentError, "Debian: Unsupported package type #{pkg.class} for #{pkg.name}"
                end
            end

            # Create an deb package of an existing ruby package
            def package_ruby(pkg, pkg_commit_time, options)
                Packager.info "Package Ruby: '#{pkg.name}' with options: #{options}"
                # update dependencies in any case, i.e. independant if package exists or not
                deps = dependencies(pkg)
                Dir.chdir(pkg.srcdir) do
                    begin
                        logname = "obs-#{pkg.name.sub("/","-")}" + "-" + Time.now.strftime("%Y%m%d-%H%M%S").to_s + ".log"
                        gem = FileList["pkg/*.gem"].first
                        if not gem
                            Packager.info "Debian: preparing gem generation in #{Dir.pwd}"

                            # Rake targets that should be tried for cleaning
                            gem_clean_success = false
                            @gem_clean_alternatives.each do |target|
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
                            Debian::generate_manifest_txt()

                            Packager.info "Debian: creating gem from package #{pkg.name} [#{File.join(log_dir, logname)}]"

                            # Allowed gem creation alternatives
                            gem_creation_success = false
                            @gem_creation_alternatives.each do |target|
                                if !system("rake #{target} >> #{File.join(log_dir, logname)} 2>> #{File.join(log_dir, logname)}")
                                    Packager.info "Debian: failed to create gem using target '#{target}'"
                                else
                                    Packager.info "Debian: succeeded to create gem using target '#{target}'"
                                    gem_creation_success = true
                                    break
                                end
                            end
                            if not gem_creation_success
                                raise RuntimeError, "Debian: failed to create gem from RubyPackage #{pkg.name}"
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

                        # Prepare injection of dependencies through options
                        # provide package name to allow consistent patching schema
                        options[:deps] = deps
                        options[:local_pkg] = true
                        options[:package_name] = pkg.name
                        convert_gem(gem_final_path, pkg_commit_time, options)
                        # register gem with the correct naming schema
                        # to make sure dependency naming and gem naming are consistent
                        @ruby_rock_gems << debian_name(pkg)
                    rescue Exception => e
                        raise RuntimeError, "Debian: failed to create gem from RubyPackage #{pkg.name} -- #{e.message}\n#{e.backtrace.join("\n")}"
                    end
                end
            end

            def self.generate_manifest_txt(directory = Dir.pwd)
                manifest_file = "Manifest.txt"
                if File.exist?(manifest_file)
                    FileUtils.rm manifest_file
                end
                Dir.glob("**/**") do |file|
                    if File.file?(file)
                       `echo #{file} >> #{manifest_file}`
                    end
                end
            end

            def package_deb(pkg, pkg_commit_time, options)
                Packager.info "Package Deb: '#{pkg.name}' with options: #{options}"

                options, unknown_options = Kernel.filter_options options,
                    :patch_dir => nil,
                    :distribution => nil,
                    :architecture => nil
                distribution = options[:distribution]

                Packager.info "Changing into packaging dir: #{packaging_dir(pkg)}"
                Dir.chdir(packaging_dir(pkg)) do
                    # Exclude hidden files
                    remove_excluded_files(pkg.srcdir, ["."])

                    # Exclude directories that are known to create conflicts, including hidden directories
                    remove_excluded_dirs(pkg.srcdir, ["debian","build",".[a-zA-Z]"])


                    sources_name = plain_versioned_name(pkg, distribution)
                    # First, generate the source tarball
                    tarball = "#{sources_name}.orig.tar.gz"

                    if options[:patch_dir] && File.exists?(options[:patch_dir])
                        patch_dir = File.join(options[:patch_dir], pkg.name)
                        if patch_directory(pkg.srcdir, patch_dir)
                            dpkg_commit_changes("deb_autopackaging_overlay")
                        end
                    end

                    # Check first if actual source contains newer information than existing
                    # orig.tar.gz -- only then we create a new debian package
                    if package_updated?(pkg)

                        Packager.warn "Package: #{pkg.name} requires update #{pkg.srcdir}"
                        if !tar_gzip(File.basename(pkg.srcdir), tarball, pkg_commit_time, distribution)
                            raise RuntimeError, "Debian: #{pkg.name} failed to create archive"
                        end

                        # Generate the debian directory
                        generate_debian_dir(pkg, pkg.srcdir, options)

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

            def package_importer(pkg, pkg_commit_time, options)
                Packager.info "Using package_importer for #{pkg.name}"
                options, unknown_options = Kernel.filter_options options,
                    :distribution => nil,
                    :architecture => nil
                distribution = options[:distribution]

                Dir.chdir(packaging_dir(pkg)) do

                    dir_name = plain_versioned_name(pkg, distribution)
                    plain_dir_name = plain_versioned_name(pkg, distribution)
                    FileUtils.rm_rf File.join(pkg.srcdir, "debian")
                    FileUtils.rm_rf File.join(pkg.srcdir, "build")

                    # Generate a CMakeLists which installs every file
                    cmake = File.new(dir_name + "/CMakeLists.txt", "w+")
                    cmake.puts "cmake_minimum_required(VERSION 2.6)"
                    add_folder_to_cmake "#{Dir.pwd}/#{dir_name}", cmake, pkg.name
                    cmake.close

                    # First, generate the source tarball
                    sources_name = plain_versioned_name(pkg, distribution)
                    tarball = "#{plain_dir_name}.orig.tar.gz"

                    # Check first if actual source contains newer information than existing
                    # orig.tar.gz -- only then we create a new debian package
                    if package_updated?(pkg)

                        Packager.warn "Package: #{pkg.name} requires update #{pkg.srcdir}"

                        source_package_dir = File.basename(pkg.srcdir)
                        if !tar_gzip(source_package_dir, tarball, pkg_commit_time)
                            raise RuntimeError, "Package: failed to tar directory #{source_package_dir}"
                        end

                        # Generate the debian directory
                        generate_debian_dir(pkg, pkg.srcdir, options)

                        # Commit local changes, e.g. check for
                        # control/urdfdom as an example
                        dpkg_commit_changes("local_build_changes", pkg.srcdir)

                        # Run dpkg-source
                        # Use the new tar ball as source
                        Packager.info `dpkg-source -I -b #{pkg.srcdir}`
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

            def build_local_gem(gem_name, options)
                gem_version = nil
                debian_package_name = rock_ruby_release_prefix + gem_name

                # Find gem version
                Find.find(File.join(build_dir,debian_package_name,"/")).each do |file|
                    if FileTest.directory?(file)
                        if File.basename(file)[0] == ?.
                            Find.prune
                        end
                    end
                    if file.end_with? ".gem"
                        gem_version = File.basename(file).sub(gem_name + '-', '').sub('.gem', '')
                        break
                    end
                end

                versioned_build_dir = debian_package_name + '-' + gem_version
                deb_filename = "#{versioned_build_dir}.deb"
                build_local(gem_name, debian_package_name, versioned_build_dir, deb_filename, options)
            end

            def build_local_package(pkg, options)
                pkg_name = pkg.name
                distribution = max_one_distribution(options[:distributions])
                versioned_build_dir = plain_versioned_name(pkg, distribution)
                deb_filename = "#{plain_versioned_name(pkg, FALSE)}_ARCHITECTURE.deb"

                build_local(pkg_name, debian_name(pkg), versioned_build_dir, deb_filename, options)
            end

            # Build package locally
            # return path to locally build file
            def build_local(pkg_name, debian_pkg_name, versioned_build_dir, deb_filename, options)
                filepath = build_dir
                distribution = max_one_distribution(options[:distributions])
                # cd package_name
                # tar -xf package_name_0.0.debian.tar.gz
                # tar -xf package_name_0.0.orig.tar.gz
                # mv debian/ package_name_0.0/
                # cd package_name_0.0/
                # debuild -us -uc
                # #to install
                # cd ..
                # sudo dpkg -i package_name_0.0.deb
                Packager.info "Building #{pkg_name} locally with arguments: pkg_name #{pkg_name}," \
                    " debian_pkg_name #{debian_pkg_name}," \
                    " versioned_build_dir #{versioned_build_dir}" \
                    " deb_filename #{deb_filename}" \
                    " options #{options}"

                begin
                    FileUtils.chdir File.join(build_dir, debian_pkg_name) do
                        if File.exists? "debian"
                            FileUtils.rm_rf "debian"
                        end
                        if File.exists? versioned_build_dir
                            FileUtils.rm_rf versioned_build_dir
                        end
                        FileUtils.mkdir versioned_build_dir

                        debian_tar_gz = Dir.glob("*.debian.tar.gz")
                        if debian_tar_gz.empty?
                            raise RuntimeError, "#{self} could not find file: *.debian.tar.gz in #{Dir.pwd}"
                        else
                            debian_tar_gz = debian_tar_gz.first
                            cmd = "tar -xf #{debian_tar_gz}"
                            if !system(cmd)
                                 raise RuntimeError, "Packager: '#{cmd}' failed"
                            end
                        end

                        orig_tar_gz = Dir.glob("*.orig.tar.gz")
                        if orig_tar_gz.empty?
                            raise RuntimeError, "#{self} could not find file: *.orig.tar.gz in #{Dir.pwd}"
                        else
                            orig_tar_gz = orig_tar_gz.first
                            cmd = "tar -x --strip-components=1 -C #{versioned_build_dir} -f #{orig_tar_gz}"
                            if !system(cmd)
                                 raise RuntimeError, "Packager: '#{cmd}' failed"
                            end
                        end

                        FileUtils.mv 'debian', versioned_build_dir + '/'
                        FileUtils.chdir versioned_build_dir do
                            pkg = Autoproj.manifest.packages[pkg_name]
                            cmd = "debuild -us -uc"
                            if pkg && pkg.autobuild
                                cmd += " -j#{pkg.autobuild.parallel_build_level}"
                            end
                            if !system(cmd)
                                raise RuntimeError, "Packager: '#{cmd}' failed"
                            end
                        end
                    end
                    filepath = Dir.glob("#{debian_pkg_name}/*.deb")
                    if filepath.size < 1
                        raise RuntimeError, "No debian file generated in #{Dir.pwd}"
                    elsif filepath.size > 1
                        raise RuntimeError, "More than one debian file available in #{Dir.pwd}: #{filepath}"
                    else
                        filepath = filepath.first
                    end
                rescue Exception => e
                    msg = "Package #{pkg_name} has not been packaged -- #{e}"
                    Packager.error msg
                    raise RuntimeError, msg
                end
                filepath
            end

            def install_debfile(deb_filename)
                cmd = "sudo dpkg -i #{deb_filename}"
                Packager.info "Installing package via: '#{cmd}'"
                if !system(cmd)
                    Packager.warn "Executing '#{cmd}' failed -- trying to fix installation"
                    cmd = "sudo apt-get install -y -f"
                    if !system(cmd)
                        raise RuntimeError, "Executing '#{cmd}' failed"
                    end
                end
            end

            # Install package
            def install(pkg_name, options)
                begin
                    pkg_build_dir = packaging_dir(pkg_name)
                    filepath = Dir.glob("#{pkg_build_dir}/*.deb")
                    if filepath.size < 1
                        raise RuntimeError, "No debian file found for #{pkg_name} in #{pkg_build_dir}: #{filepath}"
                    elsif filepath.size > 1
                        raise RuntimeError, "More than one debian file available in #{pkg_build_dir}: #{filepath}"
                    else
                        filepath = filepath.first
                        Packager.info "Found package: #{filepath}"
                    end
                    install_debfile(filepath)
                rescue Exception => e
                    raise RuntimeError, "Installation of package '#{pkg_name} failed -- #{e}"
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
                    Packager.info "No filename found for #{debian_name(pkg)} (existing files: #{Dir.entries('.')} -- package requires update (regeneration of orig.tar.gz)"
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
                        `diff -urN --exclude .* --exclude CVS --exclude debian --exclude build #{pkg.srcdir} . > #{diff_name}`
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
                [".dsc", ".orig.tar.gz", ".debian.tar.gz", ".debian.tar.xz"]
            end

            def system(*args)
                Kernel.system(*args)
            end

            # Convert all gems that are required
            # by package build with the debian packager
            def convert_gems(gems, options = Hash.new)
                Packager.info "Convert gems: #{gems} with options #{options}"
                if gems.empty?
                    return
                end

                options, unknown_options = Kernel.filter_options options,
                    :force_update => false,
                    :patch_dir => nil,
                    :local_pkg => false,
                    :distribution => target_platform.distribution_release_name,
                    :architecture => target_platform.architecture

                distribution = options[:distribution]

                if unknown_options.size > 0
                    Packager.warn "Autoproj::Packaging Unknown options provided to convert gems: #{unknown_options}"
                end

                # We use gem2deb for the job of converting the gems
                # However, since we require some gems to be patched we split the process into the
                # individual step
                # This allows to add an overlay (patch) to be added to the final directory -- which
                # requires to be commited via dpkg-source --commit
                gems.each do |gem_name, version|
                    gem_dir_name = debian_ruby_name(gem_name)

                    packaging_dirname = packaging_dir(gem_dir_name)
                    if options[:force_update]
                        if File.directory?(packaging_dirname)
                            Packager.info "Debian Gem: rebuild requested -- removing #{packaging_dirname}"
                            FileUtils.rm_rf(packaging_dirname)
                        end
                    end

                    # Assuming if the .gem file has been download we do not need to update
                    gem_globname = "#{packaging_dirname}/#{gem_name}*.gem"
                    if options[:force_update] or Dir.glob(gem_globname).empty?
                        Packager.debug "Converting gem: '#{gem_name}' to debian source package"
                        if not File.directory?( packaging_dirname )
                            FileUtils.mkdir_p packaging_dirname
                        end

                        Dir.chdir(packaging_dirname) do
                            gem_from_cache = false
                            if patch_dir = options[:patch_dir]
                                gem_dir = File.join(patch_dir, "gems", gem_name)
                                if File.directory?(gem_dir)
                                    gem = Dir.glob("#{gem_dir}/*.gem")
                                    if !gem.empty?
                                        gem_from_cache = true
                                        Packager.info "Using gem from cache: copying #{gem.first} to #{Dir.pwd}"
                                        selected_gem = nil
                                        if version
                                            regexp = Regexp.new(version)
                                            gem.each do |gem_name|
                                                if regexp.match(gem_name)
                                                    selected_gem = gem_name
                                                    break
                                                end
                                            end
                                        end
                                        if !selected_gem
                                            Packager.warn "Gem(s) in cache does not match the expected version: #{version}"
                                            raise RuntimeError, "Failed to find gem for '#{gem_name}' with version '#{version}' in cache: #{File.absolute_path(gem_dir)}"
                                        end
                                        FileUtils.cp selected_gem, "."
                                    end
                                end
                            end

                            if !gem_from_cache
                                error = true
                                max_retry = 10
                                retry_count = 1
                                loop do
                                    Packager.warn "[#{retry_count}/#{max_retry}] Retrying gem fetch #{gem_name}" if retry_count > 1
                                    if version
                                        pid = Process.spawn("gem fetch #{gem_name} --version '#{version}'")
                                        #output = `gem fetch #{gem_name} --version '#{version}'`
                                    else
                                        pid = Process.spawn("gem fetch #{gem_name}")
                                        #output = `gem fetch #{gem_name}`
                                    end
                                    begin
                                        Timeout.timeout(60) do
                                            Packager.info 'waiting for gem fetch to end'
                                            Process.wait(pid)
                                            Packager.info 'gem fetch seems successful'
                                            error = false
                                        end
                                    rescue Timeout::Error
                                        Packager.warn 'gem fetch not finished in time, killing it'
                                        Process.kill('TERM', pid)
                                        error = true
                                    end
                                    retry_count += 1
                                    break if not error or retry_count > max_retry
                                end
                            end
                        end
                        gem_file_name = Dir.glob(gem_globname).first
                        if !gem_file_name
                            raise ArgumentError, "Could not retrieve a gem for #{gem_name} #{version} and options #{options}"
                        end
                        convert_gem(gem_file_name, nil, options)
                    else
                        Packager.info "gem: #{gem_name} up to date"
                    end
                end
            end

            def patch_directory(target_dir, patch_dir)
                 if File.directory?(patch_dir)
                     Packager.warn "Applying overlay (patch) from: #{patch_dir} to #{target_dir}"
                     FileUtils.cp_r("#{patch_dir}/.", "#{target_dir}/.")

                     # We need to commit if original files have been modified
                     # so add a commit
                     orig_files = Dir["#{patch_dir}/**"].reject { |f| f["#{patch_dir}/debian/"] }
                     return if orig_files.size > 0
                 else
                     Packager.warn "No patch dir: #{patch_dir}"
                     return false
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
            #
            # default options
            #        :patch_dir => nil,
            #        :deps => {:rock => [], :osdeps => [], :nonnative => []},
            #        :distribution =>  nil
            #        :architecture => nil
            #        :local_package => false
            #
            def convert_gem(gem_path, pkg_commit_time, options = Hash.new)
                Packager.info "Convert gem: '#{gem_path}' with options: #{options}"

                options, unknown_options = Kernel.filter_options options,
                    :patch_dir => nil,
                    :deps => {:rock => [], :osdeps => [], :nonnative => []},
                    :distribution => target_platform.distribution_release_name,
                    :architecture => target_platform.architecture,
                    :local_pkg => false,
                    :package_name => nil

                if !gem_path
                    raise ArgumentError, "Debian.convert_gem: no #{gem_path} given"
                end

                distribution = options[:distribution]

                gem_base_name = ""
                Dir.chdir(File.dirname(gem_path)) do
                    gem_file_name = File.basename(gem_path)
                    gem_versioned_name = gem_file_name.sub("\.gem","")

                    # Dealing with _ in original file name, since gem2deb
                    # will debianize it
                    if gem_versioned_name =~ /(.*)(-[0-9]+\.[0-9\.-]*(-[0-9]+)*)/
                        gem_base_name = $1
                        version_suffix = gem_versioned_name.gsub(gem_base_name,"").gsub(/\.gem/,"")
                        gem_version = version_suffix.sub('-','')
                        Packager.info "gem basename: #{gem_base_name}"
                        Packager.info "gem version: #{gem_version}"
                        gem_versioned_name = gem_base_name.gsub("_","-") + version_suffix
                    else
                        raise ArgumentError, "Converting gem: unknown formatting: '#{gem_versioned_name}' -- cannot extract version"
                    end

                    ############
                    # Step 1: calling gem2tgz
                    ############
                    Packager.info "Converting gem: #{gem_versioned_name} in #{Dir.pwd}"
                    # Convert .gem to .tar.gz
                    cmd = "gem2tgz #{gem_file_name}"
                    if not system(cmd)
                        raise RuntimeError, "Converting gem: '#{gem_path}' failed -- gem2tgz failed"
                    else
                        # Unpack and repack the orig.tar.gz to
                        # (1) remove timestamps to create consistent checksums
                        # (2) remove gem2deb residues that should not be there, e.g. checksums.yaml.gz
                        # (3) guarantee consisted gem naming, e.g. ruby-concurrent turn in ruby-concurrent-0.7.2-x64-86-linux,
                        #     but we require ruby-concurrent-0.7.2
                        #
                        Packager.info "Successfully called: 'gem2tgz #{gem_file_name}' --> #{Dir.glob("**")}"
                        # Get the actual result of the conversion and unwrap
                        gem_tar_gz = Dir.glob("*.tar.gz").first
                        `tar xzf #{gem_tar_gz}`
                        FileUtils.rm gem_tar_gz

                        # Check if we need to convert the name
                        if gem_tar_gz != "#{gem_versioned_name}.tar.gz"
                            tmp_source_dir = gem_tar_gz.gsub(/.tar.gz/,"")
                            FileUtils.mv tmp_source_dir, gem_versioned_name
                        end
                        Packager.info "Converted: #{Dir.glob("**")}"

                        # https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=725348
                        checksums_file="checksums.yaml.gz"
                        files = Dir.glob("*/#{checksums_file}")
                        if not files.empty?
                            checksums_file = files.first
                        end

                        if File.exists? checksums_file
                            Packager.info "Pre-packaging cleanup: removing #{checksums_file}"
                            FileUtils.rm checksums_file
                        else
                            Packager.info "Pre-packaging cleannup: no #{checksums_file} found"
                        end


                        tgz_date = nil
                        if not pkg_commit_time.nil?
                            tgz_date = pkg_commit_time
                        else
                            ['*.gemspec','metadata.yml'].each do |file|
                                files = Dir.glob("#{gem_versioned_name}/#{file}")
                                if not files.empty?
                                    if files.first =~ /yml/
                                        spec = YAML.load_file(files.first)
                                    else
                                        spec = Gem::Specification::load(files.first)
                                    end
                                else
                                    next
                                end

                                #todo: not reliable. need sth better.
                                if spec
                                    if spec.date
                                        tgz_date = spec.date
                                        Packager.info "#{file} has associated time: using #{tgz_date} as timestamp"
                                    else
                                        Packager.warn "#{file} has no associated time: using current time for packaging"
                                    end
                                else
                                    Packager.warn "#{file} is not a spec file"
                                end
                            end
                        end
                        if !tgz_date
                            tgz_date = Time.now
                            Packager.warn "Gem conversion: could not extract time for gem: using current time: #{tgz_date}"
                        else
                            Packager.info "Gem conversion: successfully extracted time for gem: using: #{tgz_date}"
                        end

                        # Repackage
                        source_dir = gem_versioned_name
                        if !tar_gzip(source_dir, "#{gem_versioned_name}.tar.gz", tgz_date)
                            raise RuntimeError, "Failed to reformat original #{gem_versioned_name}.tar.gz for gem"
                        end
                        FileUtils.rm_rf source_dir
                        Packager.info "Converted: #{Dir.glob("**")}"
                    end


                    ############
                    # Step 2: calling dh-make-ruby
                    ############
                    # Create ruby-<name>-<version> folder including debian/ folder
                    # from .tar.gz
                    #`dh-make-ruby --ruby-versions "ruby1.9.1" #{gem_versioned_name}.tar.gz`
                    #
                    # By default generate for all ruby versions
                    # rename to the rock specific format: use option -p
                    cmd = "dh-make-ruby --ruby-versions \"all\" #{gem_versioned_name}.tar.gz -p #{rock_ruby_release_prefix}#{gem_base_name}"
                    Packager.info "calling: #{cmd}"
                    if !system(cmd)
                         Packager.warn "calling: dh-make-ruby #{gem_versioned_name}.tar.gz -p #{gem_base_name} failed"
                         raise RuntimeError, "Failed to call dh-make-ruby for #{gem_versioned_name}"
                    end

                    debian_ruby_name = debian_ruby_name(gem_versioned_name)# + '~' + distribution
                    debian_ruby_unversioned_name = debian_ruby_name.gsub(/-[0-9\.]*$/,"")
                    Packager.info "Debian ruby name: #{debian_ruby_name} -- directory #{Dir.glob("**")}"
                    Packager.info "Debian ruby unversioned name: #{debian_ruby_unversioned_name}"


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
                            if options[:package_name] && !File.exists?(gem_patch_dir)
                                gem_patch_dir = File.join(patch_dir, options[:package_name])
                            end
                            if patch_directory(Dir.pwd, gem_patch_dir)
                                dpkg_commit_changes("deb_autopackaging_overlay")
                            end
                        end

                        ################
                        # debian/install
                        ################
                        if File.exists?("debian/install")
                            `sed -i "s#/usr##{rock_install_directory}#g" debian/install`
                            dpkg_commit_changes("install_to_rock_specific_directory")
                        end

                        if File.exists?("debian/package.postinst")
                            FileUtils.mv "debian/package.postinst", "debian/#{debian_ruby_unversioned_name}.postinst"
                            dpkg_commit_changes("add_postinst_script")
                        end

                        ################
                        # debian/control
                        ################

                        # Injecting dependencies into debian/control
                        # Since we do not differentiate between build and runtime dependencies
                        # at Rock level -- we add them to both
                        #
                        # Enforces to have all dependencies available when building the packages
                        # at the build server

                        debcontrol = DebianControl.parse(File.open("debian/control"))

                        # Filter ruby versions out -- we assume chroot has installed all
                        # ruby versions
                        all_deps = options[:deps][:osdeps].select do |name|
                            name !~ /^ruby[0-9][0-9.]*/
                        end
                        options[:deps][:rock].each do |pkg|
                            all_deps << pkg
                        end

                        # Add actual gem dependencies
                        gem_deps = Hash.new
                        nonnative_packages = options[:deps][:nonnative]
                        if !nonnative_packages.empty?
                            gem_deps = GemDependencies::resolve_all(nonnative_packages)
                        elsif !options[:local_pkg]
                            gem_deps = GemDependencies::resolve_by_name(gem_base_name, gem_version)[:deps]
                        end

                        # Check if the plain package name exists in the given distribution
                        # if that is the case use that one -- if not, then use the ruby name
                        # since then is it is either part of the flow job
                        # or an os dependency
                        gem_deps = gem_deps.keys.each do |k|
                            depname, is_osdeps = native_dependency_name(k)
                            all_deps << depname
                        end
                        deps = all_deps.uniq

                        if not deps.empty?
                            Packager.info "#{debian_ruby_name}: injecting gem dependencies: #{deps.join(",")}"
                            #`sed -i "s#^\\(^Depends: .*\\)#\\1, #{deps.join(", ")},#" debian/control`
                        end

                        if options.has_key?(:package_name)
                            recursive_deps = recursive_dependencies(options[:package_name])
                        else
                            recursive_deps = nil
                        end

                        # parse and filter dependencies
                        debcontrol.packages.each do |pkg|
                            if pkg.has_key?("Depends")
                                depends = pkg["Depends"].split(/,\s*/).map { |e| e.strip }
                                depends.each do |dep|
                                    if dep =~ /^ruby-(\S+)/
                                        pkg_name = $1
                                        release_name, is_osdep = native_dependency_name(pkg_name)
                                        Packager.debug "Native dependency of ruby package: '#{pkg_name}' -- #{release_name}, is available as osdep: #{is_osdep}"
                                        if is_osdep
                                            dep.replace(release_name)
                                        else
                                            dep.replace(debian_ruby_name(pkg_name))
                                        end
                                    end
                                    if !recursive_deps.nil?
                                        dep =~ /^(\S+)/
                                        t = $1
                                        if !recursive_deps.include?(t) && !DEPWHITELIST.include?(t) && t !~ /^\${/
                                            Packager.error "Dependency #{t} required by debian/control but not by rock. Check manifest."
                                        end
                                    end
                                end
                            else
                                depends = Array.new
                            end
                            depends.concat deps
                            pkg["Depends"] = depends.uniq.join(", ") unless depends.empty?
                        end

                        # parse and filter build dependencies
                        if debcontrol.source.has_key?("Build-Depends")
                            build_depends = debcontrol.source["Build-Depends"].split(/,\s*/).map { |e| e.strip }
                            build_depends.each do |bdep|
                                if bdep =~ /^ruby-(\S+)/
                                    pkg_name = $1
                                    release_name, is_osdep = native_dependency_name(pkg_name)
                                    Packager.debug "Native dependency of ruby package: '#{pkg_name}' -- #{release_name}, is available as osdep: #{is_osdep}"
                                    if is_osdep
                                        bdep.replace(release_name)
                                    else
                                        bdep.replace(debian_ruby_name(pkg_name))
                                    end
                                end
                                if !recursive_deps.nil?
                                    bdep =~ /^(\S+)/
                                    t = $1
                                    if !recursive_deps.include?(t) && !DEPWHITELIST.include?(t) && t !~ /^\${/
                                        Packager.error "Dependency #{t} required by debian/control but not by rock. Check manifest."
                                    end
                                end
                            end
                        else
                            build_depends = Array.new
                        end

                        # Add dh-autoreconf to build dependency
                        deps << "dh-autoreconf"
                        build_depends.concat(deps)
                        #`sed -i "s#^\\(^Build-Depends: .*\\)#\\1, #{deps.join(", ")},#" debian/control`

                        debcontrol.source["Build-Depends"] = build_depends.uniq.join(", ")
                        File.write("debian/control", DebianControl::generate(debcontrol))
                        dpkg_commit_changes("deb_extra_dependencies")

                        Packager.info "Relaxing version requirement for: debhelper and gem2deb"
                        # Relaxing the required gem2deb version to allow for for multiplatform support
                        #`sed -i "s#^\\(^Build-Depends: .*\\)gem2deb (>= [0-9\.~]\\+)\\(, .*\\)#\\1 gem2deb\\2#g" debian/control`
                        #`sed -i "s#^\\(^Build-Depends: .*\\)debhelper (>= [0-9\.~]\\+)\\(, .*\\)#\\1 debhelper\\2#g" debian/control`
                        build_depends.each do |bdep|
                            bdep.replace("gem2deb") if bdep =~ /gem2deb.+/
                            bdep.replace("debhelper") if bdep =~ /debhelper.+/
                        end
                        debcontrol.source["Build-Depends"] = build_depends.uniq.join(", ")
                        File.write("debian/control", DebianControl::generate(debcontrol))
                        dpkg_commit_changes("relax_version_requirements")

                        Packager.info "Change to 'any' architecture"
                        #`sed -i "s#Architecture: all#Architecture: any#" debian/control`
                        debcontrol.packages.each do |pkg|
                          pkg["Architecture"] = "any"
                        end
                        File.write("debian/control", DebianControl::generate(debcontrol))
                        dpkg_commit_changes("any-architecture")

                        #-- e.g. for overlays use the original name in the control file
                        # which will be overwritten here
                        Packager.info "Adapt original package name if it exists"
                        original_name = debian_ruby_name(gem_base_name, false)
                        release_name = debian_ruby_name(gem_base_name, true)
                        # Avoid replacing parts of the release name, when it is already adapted
                        # rock-master-ruby-facets with ruby-facets
                        `sed -i "s##{release_name}##{original_name}#g" debian/*`
                        # Inject the true name
                        `sed -i "s##{original_name}##{release_name}#g" debian/*`
                        dpkg_commit_changes("adapt_original_package_name")

                        ################
                        # debian/rules
                        ################

                        # Injecting environment setup in debian/rules
                        # packages like orocos.rb will require locally installed packages

                        Packager.info "#{debian_ruby_name}: injecting enviroment variables into debian/rules"
                        Packager.debug "Allow custom rock name and installation path: #{rock_install_directory}"
                        Packager.debug "Enable custom rock name and custom installation path"

                        `sed -i '1 a env_setup += RUBY_CMAKE_INSTALL_PREFIX=#{File.join("debian",debian_ruby_unversioned_name, rock_install_directory)}' debian/rules`
                        envsh = Regexp.escape(env_setup())
                        `sed -i '1 a #{envsh}' debian/rules`
                        ruby_arch_env = Regexp.escape(ruby_arch_setup())
                        `sed -i '1 a #{ruby_arch_env}' debian/rules`
                        `sed -i '1 a export DH_RUBY_INSTALL_PREFIX=#{rock_install_directory}' debian/rules`
                        `sed -i "s#\\(dh \\)#\\$(env_setup) \\1#" debian/rules`

                        # Ignore all ruby test results when the binary package is build (on the build server)
                        # via:
                        # dpkg-buildpackage -us -uc
                        #
                        # Thus uncommented line of
                        # export DH_RUBY_IGNORE_TESTS=all
                        Packager.debug "Disabling tests including ruby test result evaluation"
                        `sed -i 's/#\\(export DH_RUBY_IGNORE_TESTS=all\\)/\\1/' debian/rules`
                        # Add DEB_BUILD_OPTIONS=nocheck
                        # https://www.debian.org/doc/debian-policy/ch-source.html
                        `sed -i '1 a export DEB_BUILD_OPTIONS=nocheck' debian/rules`
                        dpkg_commit_changes("disable_tests")


                        ["debian","pkgconfig"].each do |subdir|
                            Dir.glob("#{subdir}/*").each do |file|
                                `sed -i "s#\@ROCK_INSTALL_DIR\@##{rock_install_directory}#g" #{file}`
                                dpkg_commit_changes("adapt_rock_install_dir")
                            end
                        end

                        ###################
                        # debian/changelog
                        #################################
                        # Any change of the version in the changelog file will directly affect the
                        # naming of the *.debian.tar.gz and the *.dsc file
                        #
                        # Subsequently also the debian package will be (re)named according to this
                        # version string.
                        #
                        # When getting an error such as '"ruby-utilrb_3.0.0.rc1-1.dsc" is already registered with different checksums'
                        # then you probably miss the distribution information or it is not correctly injected
                        if distribution
                            # Changelog entry initially, e.g.,
                            # ruby-activesupport (4.2.3-1) UNRELEASED; urgency=medium
                            #
                            # after
                            # ruby-activesupport (4.2.3-1~trusty) UNRELEASED; urgency=medium
                            if `sed -i 's#\(\\(.*\\)\)#\(\\1~#{distribution}\)#' debian/changelog`
                                Packager.info "Injecting distribution info: '~#{distribution}' into debian/changelog"
                            else
                                raise RuntimeError, "Failed to inject distribution information into debian/changelog"
                            end

                            # Make timestamp constant
                            # https://www.debian.org/doc/debian-policy/ch-source.html
                            #
                            date=`date --rfc-2822 --date="00:00:01"`
                            date=date.strip
                            if `sed -i 's#\\(.*<.*>  \\)\\(.*\\)#\\1#{date}#' debian/changelog`
                                Packager.info "Injecting timestamp info: '#{date}' into debian/changelog"
                            else
                                raise RuntimeError, "Failed to inject timestamp information into debian/changelog"
                            end

                            #FileUtils.cp "debian/changelog","/tmp/test-changelog"
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

            def extra_configure_flags(package)
                flags = []
                key_value_regexp = Regexp.new(/([^=]+)=([^=]+)/)
                package.configureflags.each do |flag|
                    if match_data = key_value_regexp.match(flag)
                        key = match_data[1]
                        value = match_data[2]
                        # Skip keys that start with --arguments
                        # and assume defines starting with UpperCase
                        # letter, e.g., CFLAGS='...'
                        if key =~ /^[A-Z]/
                            if value !~ /^["]/ && value !~ /^[']/
                                value = "'#{match_data[2]}'"
                            end
                        end
                        flags << "#{key}=#{value}"
                    else
                        flags << flag
                    end
                end
                Packager.info "Using extra configure flags: #{flags}"
                flags
            end

            # Sort by package set order
            def sort_by_package_sets(packages, pkg_set_order)
                priority_lists = Array.new
                (0..pkg_set_order.size).each do |i|
                    priority_lists << Array.new
                end

                packages.each do |package|
                    if !package.kind_of?(String)
                        package = package.name
                    end
                    pkg = Autoproj.manifest.package(package)
                    pkg_set_name = pkg.package_set.name

                    if index = pkg_set_order.index(pkg_set_name)
                        priority_lists[index] << package
                    else
                        priority_lists.last << package
                    end
                end

                priority_lists.flatten
            end

            def ruby_arch_setup
                Packager.info "Creating ruby env setup"
                setup = "arch=$(shell gcc -print-multiarch)\n"
                # Extract the default ruby version to build for on that platform
                # this assumes a proper setup of /usr/bin/ruby
                setup +="ruby_ver=$(shell ruby --version)\n"
                setup += "ruby_arch_dir=$(shell ruby -r rbconfig -e \"print RbConfig::CONFIG['archdir']\")\n"
                setup += "ruby_libdir=$(shell ruby -r rbconfig -e \"print RbConfig::CONFIG['rubylibdir']\")\n"

                setup += "rockruby_archdir=$(subst /usr,,$(ruby_arch_dir))\n"
                setup += "rockruby_libdir=$(subst /usr,,$(ruby_libdir))\n"
                setup
            end

            def env_setup
                Packager.info "Creating envsh"
                path_env            = "PATH="
                rubylib_env         = "RUBYLIB="
                pkgconfig_env       = "PKG_CONFIG_PATH="
                rock_dir_env        = "Rock_DIR="
                ld_library_path_env = "LD_LIBRARY_PATH="
                cmake_prefix_path   = "CMAKE_PREFIX_PATH="
                orogen_plugin_path  = "OROGEN_PLUGIN_PATH="

                rock_release_hierarchy.each do |release_name|
                    install_dir = File.join(rock_base_install_directory, release_name)
                    path_env    += "#{File.join(install_dir, "bin")}:"

                    # Update execution path for orogen, so that it picks up ruby-facets (since we don't put much effort into standardizing facets it installs in
                    # vendor_ruby/standard and vendory_ruby/core) -- from Ubuntu 13.04 ruby-facets will be properly packaged
                    rubylib_env += "#{File.join(install_dir, "$(rockruby_libdir)")}:"
                    rubylib_env += "#{File.join(install_dir, "$(rockruby_archdir)")}:"
                    rubylib_env += "#{File.join(install_dir, "lib/ruby/vendor_ruby/standard")}:"
                    rubylib_env += "#{File.join(install_dir, "lib/ruby/vendor_ruby/core")}:"
                    rubylib_env += "#{File.join(install_dir, "lib/ruby/vendor_ruby")}:"

                    pkgconfig_env += "#{File.join(install_dir,"lib/pkgconfig")}:"
                    pkgconfig_env += "#{File.join(install_dir,"lib/$(arch)/pkgconfig")}:"
                    rock_dir_env += "#{File.join(install_dir,"share/rock/cmake")}:"
                    ld_library_path_env += "#{File.join(install_dir,"lib")}:#{File.join(install_dir,"lib/$(arch)")}:"
                    cmake_prefix_path += "#{install_dir}:"
                    orogen_plugin_path += "#{File.join(install_dir,"share/orogen/plugins")}:"
                end

                pkgconfig_env       += "/usr/share/pkgconfig:/usr/lib/$(arch)/pkgconfig:"

                path_env            += "$(PATH)"
                rubylib_env         += "$(RUBYLIB)"
                pkgconfig_env       += "$(PKG_CONFIG_PATH)"
                rock_dir_env        += "$(Rock_DIR)"
                ld_library_path_env += "$(LD_LIBRARY_PATH)"
                cmake_prefix_path   += "$(CMAKE_PREFIX_PATH)"
                orogen_plugin_path  += "$(OROGEN_PLUGIN_PATH)"

                envsh =  "env_setup =  #{path_env}\n"
                envsh += "env_setup += #{rubylib_env}\n"
                envsh += "env_setup += #{pkgconfig_env}\n"
                envsh += "env_setup += #{rock_dir_env}\n"
                envsh += "env_setup += #{ld_library_path_env}\n"
                envsh += "env_setup += #{cmake_prefix_path}\n"
                envsh += "env_setup += #{orogen_plugin_path}\n"

                if ["xenial"].include?(target_platform.distribution_release_name)
                    envsh += "export TYPELIB_CXX_LOADER=castxml\n"
                end
                envsh += "export DEB_CPPFLAGS_APPEND='-std=c++11'\n"
                envsh += "rock_install_dir=#{rock_install_directory}"
                envsh
            end
        end #end Debian
    end
end

