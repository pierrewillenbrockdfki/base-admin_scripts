require 'erb'
require 'optparse'
require_relative 'packager'
require_relative 'config'

module Autoproj
    module Packaging
        class Installer
            extend Logger::Root("Installer", Logger::INFO)

            BUILDER_DEBS=["dh-autoreconf","cdbs","cmake","apt","apt-utils","cowbuilder","cowdancer","debian-archive-keyring","pbuilder","qemubuilder","qemu-user-static"]
            WEBSERVER_DEBS=["apache2"]
            CHROOT_EXTRA_DEBS=['cdbs','lintian','fakeroot','doxygen','graphviz']
            PBUILDER_CACHE_DIR="/var/cache/pbuilder"

            @base_image_lock = Mutex.new

            class ChrootCmdError < StandardError
                attr_reader :status

                def initialize(status)
                    @status = status
                end
            end

            # Create the webserver configuration required to host the reprepro repositories
            def self.create_webserver_config(document_root, packages_subfolder,
                                             release_prefix, target_path)

                Installer.info "Creating webserver configuration: \n" \
                    "    document root: #{document_root}\n" \
                    "    packages_subfolder: #{packages_subfolder}\n" \
                    "    release_prefix: #{release_prefix}\n" \
                    "    target_path: #{target_path}"

                template_dir = File.expand_path(File.join(File.dirname(__FILE__),"templates","webserver"))
                apache_config_template = File.join(template_dir, "jenkins.conf")

                template = ERB.new(File.read(apache_config_template), nil, "%<>")
                rendered = template.result(binding)

                File.open(target_path, "w") do |io|
                    io.write(rendered)
                end
                Installer.debug "Written config file: #{target_path}"
            end

            # Install the webserver configuration required to host the reprepro repositories
            # @param config_path [String]
            # @param release_prefix [String]
            # @return [String] path the generated and installed configuration
            def self.install_webserver_config(config_path, release_prefix)
                target_config_file = "100_reprepro-#{release_prefix}.conf"
                apache_config = File.join("/etc","apache2","sites-available",target_config_file)
                system("sudo", "cp", config_path, apache_config, :close_others => true)
                if $?.exitstatus == 0
                    system("sudo", "a2ensite", target_config_file, :close_others => true)
                    if $?.exitstatus == 0
                        system("sudo", "service", "apache2", "reload", :close_others => true)
                        Installer.info "Activated apache site #{apache_config}"
                    else
                        Installer.warn "#{cmd} failed -- could not enable apache site #{apache_config}"
                    end
                else
                    Installer.warn "#{cmd} failed -- could not install site #{config_path} as #{apache_config}"
                end
                apache_config
            end

            # Install all required packages to build
            # debian packages and host them using apache and reprepro
            def self.install_all_requirements
                install_pbuilder_conf

                install_package_list BUILDER_DEBS
                install_package_list WEBSERVER_DEBS
            end

            # Install a given list of packages
            # @param list [Array] Array of packages to install
            def self.install_package_list(list = Array.new)
                list.each do |pkg_name|
                    install_package pkg_name
                end
            end

            # Install a package with the given name
            # @param package_name [String] package name
            def self.install_package(package_name)
                if !installed?(package_name)
                    Installer.info "Installing '#{package_name}'"
                    system("sudo", "apt-get", "-y", "install", package_name, :close_others => true)
                end
            end

            # Check with dpkg if a package with the given name is already installed
            # @param package_name [String] name of the package
            # @return [Bool] true if package is already installed, false otherwise
            def self.installed?(package_name)
                if !system("dpkg", "-l", package_name, :close_others => true)
                    Installer.info "'#{package_name}' is not yet installed"
                    return false
                else
                    Installer.info "'#{package_name}' is already installed"
                    return true
                end
            end

            # Install the pbuilder configuration from the existing template
            # @return [String] path to the pbuilder configuration file
            def self.install_pbuilder_conf
                pbuilder_conf = File.join(TEMPLATES_DIR,"etc-pbuilderrc")
                system("sudo", "cp", pbuilder_conf, "/etc/pbuilderrc", :close_others => true)
                Installer.info "Installed #{pbuilder_conf} as /etc/pbuilderrc"
                return "/etc/pbuilderrc"
            end

            # Setup an image/chroot
            # @param distribution [String] name of the distribution, e.g., xenial
            # @param architecture [String] name of the architecture, e.g., amd64, i386 or armel
            # @param release_prefix [String] name of the release that is being generated
            # @param options [Hash] list of options, currently allowed: patch_dir: path to the patch directories
            def self.image_setup(distribution, architecture, release_prefix, options = Hash.new)
                options, unknown_options = Kernel.filter_options options,
                    :patch_dir => nil

                @base_image_lock.lock
                begin

                    image_prepare(distribution, architecture)
                    image_update(distribution, architecture)
                    image_prepare_hookdir(distribution, architecture, release_prefix)

                    CHROOT_EXTRA_DEBS.each do |extra_pkg|
                        image_install_pkg(distribution, architecture, extra_pkg)
                    end
                    # If gem2deb_base_dir is given, then it will be tried to update
                    # (install a patched version of) gem2deb in the target chroot
                    # (if possible)
                    #
                    if options[:patch_dir]
                        gem2deb_base_dir = File.join(options[:patch_dir],"gem2deb")
                        image_update_gem2deb(distribution, architecture, gem2deb_base_dir)
                    end
                ensure
                    @base_image_lock.unlock
                end
            end

            # Install a particular package into a chroot using 'apt'
            # @param distribution [String] name of the distribution, e.g., xenial
            # @param architecture [String] name of the architecture, e.g., amd64, i386 or armel
            # @param pkg [String] name of the package to install
            def self.image_install_pkg(distribution, architecture, pkg)
                if !@base_image_lock.owned?
                    raise ThreadError.new
                end
                basepath = image_basepath(distribution, architecture)
                chroot_cmd(basepath, "apt-get install -y #{pkg}")
            end


            # Install a particular package into a chroot using 'dpkg'
            # @param distribution [String] name of the distribution, e.g., xenial
            # @param architecture [String] name of the architecture, e.g., amd64, i386 or armel
            # @param debfile [String] name of the debian package file to install
            def self.image_install_debfile(distribution, architecture, debfile)
                if !@base_image_lock.owned?
                    raise ThreadError.new
                end
                basepath = image_basepath(distribution, architecture)
                begin
                    chroot_cmd(basepath, "dpkg -i #{debfile}")
                rescue ChrootCmdError => e
                    if e.status.exited? && e.status.exitstatus == 1
                        #try again, fixing the dependencies beforehand.
                        chroot_cmd(basepath, "apt-get -f install -y")
                        chroot_cmd(basepath, "dpkg -i #{debfile}")
                    else
                        raise
                    end
                end
            end

            # Get the base path to an image, e.g.
            #  base-trusty-amd64.cow
            # @param distribution [String] name of the distribution, e.g., xenial
            # @param architecture [String] name of the architecture, e.g., amd64, i386 or armel
            def self.image_basepath(distribution, architecture)
                name="base-#{distribution}-#{architecture}.cow"
                File.join(PBUILDER_CACHE_DIR, name)
            end

            # Prepare the chroot/image in order to build for different target
            # architectures
            # @param distribution [String] name of the distribution, e.g., xenial
            # @param architecture [String] name of the architecture, e.g., amd64, i386 or armel
            def self.image_prepare(distribution, architecture)
                if !@base_image_lock.owned?
                    raise ThreadError.new
                end
                basepath = image_basepath(distribution,architecture)

                if File.exist?(basepath)
                    Installer.info "Image #{basepath} already exists"
                else
                    cmd = ["sudo"]
                    cmd << "DIST=#{distribution}" << "ARCH=#{architecture}" <<
                        "cowbuilder" << "--create" <<
                        "--basepath" << basepath <<
                        "--distribution" << distribution <<
                        "--architecture" << architecture

                    if !system(*cmd, :close_others => true)
                        raise RuntimeError, "#{self} failed to create base-image: #{basepath}"
                    else
                        Installer.info "Successfully created base-image: #{basepath}"
                    end
                end
            end

            # Update the chroot/image using `cowbuilder --update`
            # @param distribution [String] name of the distribution, e.g., xenial
            # @param architecture [String] name of the architecture, e.g., amd64, i386 or armel
            def self.image_update(distribution, architecture)
                if !@base_image_lock.owned?
                    raise ThreadError.new
                end
                basepath = image_basepath(distribution, architecture)
                cmd = ["sudo"]
                cmd << "DIST=#{distribution}" << "ARCH=#{architecture}"
                cmd << "cowbuilder" << "--update" <<
                    "--basepath" << basepath

                if !system(*cmd, :close_others => true)
                    raise RuntimeError, "#{self} failed to update base-image: #{basepath}"
                else
                    Installer.info "Successfully update base-image: #{basepath}"
                end

                # Set default ruby version
                if ["trusty"].include?(distribution)
                    #make sure a usable ruby version is installed
                    image_install_pkg(distribution, architecture, "ruby2.0")
                    chroot_cmd(basepath, "dpkg-divert --add --rename --divert /usr/bin/ruby.divert /usr/bin/ruby")
                    chroot_cmd(basepath, "dpkg-divert --add --rename --divert /usr/bin/ruby.divert /usr/bin/ruby")
                    chroot_cmd(basepath, "dpkg-divert --add --rename --divert /usr/bin/gem.divert /usr/bin/gem")
                    chroot_cmd(basepath, "update-alternatives --install /usr/bin/ruby ruby /usr/bin/ruby2.0 1")
                    chroot_cmd(basepath, "update-alternatives --install /usr/bin/ruby ruby /usr/bin/gem2.0 1")
                end
            end

            # Execute a command in the given chroot
            def self.chroot_cmd(basepath, cmd)
                #todo: can we get this to be somewhat more safe, like
                #passing all arguments as actual arguments
                if !system("sudo", "chroot", basepath, "/bin/bash", "-c", cmd,
                          :close_others => true)
                    # No need to do any extra processing on $?, sudo tries
                    # hard to be transparent to the exit status, even
                    # resignalling itself as needed.
                    # The only non-transparent behaviour is when the execution
                    # is not permitted(exitstatus is 1) or sudo encounters
                    # an internal problem(exitstatus is 2)
                    raise ChrootCmdError.new($?), "#{self} -- Execution: #{cmd} failed for basepath: #{basepath}"
                end
            end

            # Update the gem2deb version if a patched version is available
            # An update is typically required, since the standard versions of gem2deb do not support
            # the installation into custom directories, such as /opt instead of /usr
            # As such corresponding updated debs can be installed and put into a folder named
            # <gem2deb_debs_basedir>/<distribution>-all/
            # @param distribution [String] name of the distribution, e.g., xenial
            # @param architecture [String] name of the architecture, e.g., amd64, i386 or armel
            # @param gem2deb_debs_basedir [String] base-directory where the precompiled gem2deb packages are located
            def self.image_update_gem2deb(distribution, architecture, gem2deb_debs_basedir)
                if !@base_image_lock.owned?
                    raise ThreadError.new
                end
                basepath = image_basepath(distribution, architecture)

                gem2deb_debs_dir = File.join(gem2deb_debs_basedir,"#{distribution}-all")
                if !File.exist?(gem2deb_debs_dir)
                    raise ArgumentError, "#{self} -- Cannot update gem2deb in chroot #{basepath}. " \
                        "Debian package directory: #{gem2deb_debs_dir} does not exist"
                end

                gem2deb_debfile = Dir.glob(File.join(gem2deb_debs_dir,"gem2deb_*.deb"))
                if gem2deb_debfile.empty?
                    raise ArgumentError, "#{self} -- Cannot update gem2deb in chroot #{basepath}. " \
                        "Debian package directory: #{gem2deb_debs_dir} does not contain a deb file"
                else
                    gem2deb_debfile = File.basename(gem2deb_debfile.first)
                end

                gem2deb_test_runner_debfile = Dir.glob(File.join(gem2deb_debs_dir,"gem2deb-test-runner_*.deb"))
                if !gem2deb_test_runner_debfile.empty?
                    gem2deb_test_runner_debfile = File.basename(gem2deb_test_runner_debfile.first)
                end

                mountbase = "mnt"
                mountdir = File.join(basepath,mountbase)
                cmd = ["sudo"]
                cmd << "mount" << "--bind" << gem2deb_debs_dir << mountdir
                if !system(*cmd, :close_others => true)
                    raise RuntimeError, "#{self} -- Execution: #{cmd.join(" ")} failed"
                end

                begin
                    if !gem2deb_test_runner_debfile.empty?
                        image_install_debfile(distribution, architecture, "/#{mountbase}/#{gem2deb_test_runner_debfile}")
                    end
                    image_install_debfile(distribution, architecture, "/#{mountbase}/#{gem2deb_debfile}")
                ensure
                    cmd = ["sudo"]
                    cmd << "umount" << mountdir
                    if !system(*cmd, :close_others => true)
                        raise RuntimeError, "#{self} -- Execution: #{cmd.join(" ")} failed"
                    end
                end
            end

            # Construct the name of the pbuild hook directory from the distribution name, architecture
            # and the release prefix
            def self.pbuilder_hookdir(distribution, architecture, release_prefix)
                base_hook_dir = File.join(Autoproj::Packaging::build_dir,"pbuilder-hookdir")
                hook_dir = File.join(base_hook_dir,"#{distribution}-#{architecture}-#{release_prefix}")
                hook_dir
            end

            # Prepare the hook file to allow inclusion of the already generated
            # packages
            # This also takes care of the inclusion of dependant releases
            def self.image_prepare_hookdir(distribution,architecture, release_prefix)
                if !@base_image_lock.owned?
                    raise ThreadError.new
                end
                hook_dir = pbuilder_hookdir(distribution, architecture, release_prefix)
                rock_release_platform = TargetPlatform.new(release_prefix, architecture)
                if !File.exist?(hook_dir)
                    FileUtils.mkdir_p hook_dir
                end
                filename = "D05deps"
                Dir.chdir(hook_dir) do
                    File.open(filename, "w") do |f|
                        f.write("#!/bin/bash\n")
                        f.write("set -ex\n")

                        # First check if the url for the repository is given and that is what is preferably used for consistency
                        # If the url should not be used, then it should not be provided in the configuration file
                        # Otherwise the locally found repository will be used -- for this bindmount options need to be set correctly see build_package_from_dsc
                        url = Autoproj::Packaging::Config.release_url(release_prefix)
                        if url
                            Installer.warn "Autoproj::Packaging::Installer.image_prepare_hookdir -- using package url #{url} for release #{release_prefix}"
                            f.write("echo \"deb [trusted=yes] #{url} #{distribution} main\" > /etc/apt/sources.list.d/rock-#{release_prefix}.list\n")
                        else
                            release_repo = File.join(DEB_REPOSITORY,release_prefix)
                            if File.exists?(release_repo)
                                Installer.warn "Autoproj::Packaging::Installer.image_prepare_hookdir -- using local repositories #{release_repo} for release #{release_prefix}"
                                f.write("echo \"deb [trusted=yes] file://#{release_repo} #{distribution} main\" > /etc/apt/sources.list.d/rock-#{release_prefix}.list\n")
                            else
                                raise RuntimeError, "Autoproj::Packaging::Installer.image_prepare_hookdir: failed to identify repository for #{release_name}\n" \
                                             "     - no url found in configuration\n" \
                                             "     - no local repository #{release_repo} found"

                            end
                        end

                        rock_release_platform.ancestors.each do |ancestor_name|
                            if TargetPlatform::isRock(ancestor_name)
                                url = Autoproj::Packaging::Config.release_url(ancestor_name)
                                if url
                                    Installer.warn "Autoproj::Packaging::Installer.image_prepare_hookdir -- using package url #{url} for release ancestor #{ancestor_name}"
                                    f.write("echo \"deb [trusted=yes] #{url} #{distribution} main\" > /etc/apt/sources.list.d/rock-#{ancestor_name}.list\n")
                                else
                                    release_repo = File.join(DEB_REPOSITORY,ancestor_name)
                                    if File.exists?(release_repo)
                                        Installer.warn "Autoproj::Packaging::Installer.image_prepare_hookdir -- using local repositories #{release_repo} for ancestor release #{ancestor_name}"
                                        f.write("echo \"deb [trusted=yes] file://#{release_repo} #{distribution} main\" > /etc/apt/sources.list.d/rock-#{ancestor_name}.list\n")
                                    else
                                        raise RuntimeError, "Autoproj::Packaging::Installer.image_prepare_hookdir: failed to identify repository for #{ancestor_name}\n" \
                                             "     - no url found in configuration\n" \
                                             "     - no local repository #{release_repo} found"
                                    end
                                end
                            end
                        end
                        f.write("/usr/bin/apt-get update\n")
                    end
                    Packager.info "Changing filemode of: #{filename} in #{Dir.pwd}"
                    FileUtils.chmod 0755, filename
                end
            end

            # sudo DIST=jessie ARCH=amd64 cowbuilder --build
            # rock-local-base-types_0.20160923-1\~trusty.dsc --basepath
            # /var/cache/pbuilder/base-jessie-amd64.cow --buildresult binaries
            # --debbuildopts -sa --bindmounts '/var/www/rock-reprepro/local'
            # --hookdir /opt/workspace/drock/dev/build/rock-packager/pbuilder-hooks
            #
            def self.build_package_from_dsc(dsc_file, distribution, architecture, release_prefix, options)
                build_options, unknown_build_options = Kernel.filter_options options,
                    :result_dir => Dir.pwd,
                    :log_file => nil

                image_setup(distribution, architecture, release_prefix, options)
                rock_release_platform = TargetPlatform.new(release_prefix, architecture)

                cmd  = ["sudo", "DIST=#{distribution}", "ARCH=#{architecture}"]
                cmd << "cowbuilder" << "--build" << dsc_file
                cmd << "--basepath" << image_basepath(distribution, architecture)
                cmd << "--buildresult" << build_options[:result_dir]
                cmd << "--debbuildopts" << "-sa"
                bindmounts = [File.join(DEB_REPOSITORY, release_prefix)]
                rock_release_platform.ancestors.each do |ancestor_name|
                    if TargetPlatform::isRock(ancestor_name)
                        # Check if url will be used, otherwise the local repository has to be mounted
                        if !Autoproj::Packaging::Config.release_url(ancestor_name)
                            bindmounts << File.join(DEB_REPOSITORY, ancestor_name)
                        end
                    end
                end

                cmd << "--bindmounts" << bindmounts.join(" ")

                cmd << "--hookdir" << pbuilder_hookdir(distribution, architecture, release_prefix)
                cmdopts = {:close_others => true}
                if log_file = build_options[:log_file]
                    # \z to match the end of the string (compared to $ end of line)
                    pbuilder_log_file = log_file.sub(/\.[^.]+\z/, "-pbuilder.log")
                    cmd << "--logfile" << pbuilder_log_file
                    cmdopts[[:out, :err]] = log_file
                end
                begin
                    if !system(*cmd, cmdopts)
                        Installer.warn "Failed to build package for #{dsc_file} using: \"#{cmd.join("\" \"")}\"" +
                                       if build_options[:log_file]
                                           " &> #{build_options[:log_file]}"
                                       end
                    end
                rescue Exception
                    puts "Exception during package build using for #{dsc_file} using: \"#{cmd.join("\" \"")}\""
                    raise
                end
            end
        end
    end
end
