require 'autobuild/config'
require 'autobuild/exceptions'

# This class is the base class for objects that are used to get the source from
# various RCS into the package source directory. A list of patches to apply
# after the import can be given in the +:patches+ option.
module Autobuild
class Importer
    # call-seq:
    #   Autobuild::Importer.fallback { |package, importer| ... }
    #
    # If called, registers the given block as a fallback mechanism for failing
    # imports.
    #
    # Fallbacks are tried in reverse order with the failing importer object as
    # argument. The first valid importer object that has been returned will be
    # used instead.
    #
    # It is the responsibility of the fallback handler to make sure that it does
    # not do infinite recursions and stuff like that.
    def self.fallback(&block)
        @fallback_handlers.unshift(block)
    end

    class << self
        # The set of handlers registered by Importer.fallback
        attr_reader :fallback_handlers
    end

    @fallback_handlers = Array.new

    # Instances of the Importer::Status class represent the status of a current
    # checkout w.r.t. the remote repository.
    class Status
        # Remote and local are at the same point
        UP_TO_DATE    = 0
        # Local contains all data that remote has, but has new commits
        ADVANCED      = 1
        # Next update will require a merge
        NEEDS_MERGE   = 2
        # Next update will be simple (no merge)
        SIMPLE_UPDATE = 3

        # The update status
        attr_accessor :status
        # True if there is code in the working copy that is not committed
        attr_accessor :uncommitted_code

        # An array of strings that represent commits that are in the remote
        # repository and not in this one (would be merged by an update)
        attr_accessor :remote_commits
        # An array of strings that represent commits that are in the local
        # repository and not in the remote one (would be pushed by an update)
        attr_accessor :local_commits

        def initialize
            @status = -1
            @uncommitted_code = false
            @remote_commits = Array.new
            @local_commits  = Array.new
        end
    end

    # Creates a new Importer object. The options known to Importer are:
    # [:patches] a list of patch to apply after import
    #
    # More options are specific to each importer type.
    def initialize(options); @options = options end

    def patches
        if @options[:patches].respond_to?(:to_ary)
            @options[:patches]
        elsif !@options[:patches]
            []
        else
            [@options[:patches]]
        end
    end

    def perform_update(package)
        cur_patches = currently_applied_patches(package)
        needed_patches = self.patches
        kept_patches = (cur_patches & needed_patches)
        if kept_patches != cur_patches
            patch(package, kept_patches)
        end

        package.progress "updating %s"
        update(package)
        patch(package)
        package.updated = true
    rescue Interrupt
        raise
    rescue ::Exception => original_error
        # If the package is patched, it might be that the update
        # failed because we needed to unpatch first. Try it out
        #
        # This assumes that importing data with conflict will
        # make the import fail, but not make the patch
        # un-appliable. Importers that do not follow this rule
        # will have to unpatch by themselves.
        cur_patches = currently_applied_patches(package)
        if cur_patches.empty?
            return fallback(original_error, package, :import, package)
        end

        package.progress "update failed and some patches are applied, retrying after removing all patches first"
        begin
            patch(package, [])

        rescue ::Exception => e
            # The unpatching failed. The importer probably did
            # change the files in a way that made the patching
            # impossible to reverse. Just raise the original
            # error (which hopefully should be the importer
            # message that says that there are conflicts)
            raise original_error
        end

        begin
            package.progress "updating %s"
            update(package)
            patch(package)
            package.updated = true
        rescue Interrupt
            raise
        rescue ::Exception => e
            fallback(e, package, :import, package)
        end
    end

    def perform_checkout(package)
        package.progress "checking out %s"
        checkout(package)
        patch(package)
        package.updated = true
    rescue Autobuild::Exception => e
        FileUtils.rm_rf package.srcdir
        fallback(e, package, :import, package)
    rescue ::Exception
        package.progress "checkout of %s failed, deleting the source directory #{package.srcdir}"
        FileUtils.rm_rf package.srcdir
        raise
    end

    # Performs the import of +package+
    def import(package)
        srcdir = package.srcdir
        if File.directory?(srcdir)
            package.isolate_errors(false) do
                if Autobuild.do_update
                    perform_update(package)
                else
                    if Autobuild.verbose
                        puts "  not updating #{package.name}"
                    end
                    return
                end
            end

        elsif File.exists?(srcdir)
            raise ConfigException, "#{srcdir} exists but is not a directory"
        else
            perform_checkout(package)
        end
    end

    # Tries to find a fallback importer because of the given error.
    def fallback(error, package, *args, &block)
        puts "Error Code #{error.status}" if error.respond_to?(:status)
        Importer.fallback_handlers.each do |handler|
            fallback_importer = handler.call(package, self)
            if fallback_importer.kind_of?(Importer)
                begin
                    return fallback_importer.send(*args, &block)
                rescue Exception
                    # raise error
                end
            end
        end
        raise error
    end

    private
    
    # We assume that package.srcdir already exists (checkout is supposed to
    # have been called)
    def patchlist(package)
        File.join(package.srcdir, "patches-autobuild-stamp")
    end

    def call_patch(package, reverse, file)
        patch = Autobuild.tool('patch')
        Dir.chdir(package.srcdir) do
            Subprocess.run(package, :patch, patch, '-p0', (reverse ? '-R' : nil), '--forward', :input => file)
        end
    end

    def apply(package, path);   call_patch(package, false, path) end
    def unapply(package, path); call_patch(package, true, path)   end

    def currently_applied_patches(package)
        patches_file = patchlist(package)
        if !File.exists?(patches_file) then []
        else
            File.open(patches_file) do |f| 
                f.readlines.collect { |path| path.rstrip } 
            end
        end
    end

    def patch(package, patches = self.patches)
        # Get the list of already applied patches
        cur_patches = currently_applied_patches(package)

        if cur_patches == patches
            return false
        end

        # Do not be smart, remove all already applied patches
        # and then apply the new ones
        begin
            apply_count = (patches - cur_patches).size
            unapply_count = (cur_patches - patches).size
            if apply_count > 0 && unapply_count > 0
                package.progress "patching %s: applying #{apply_count} and unapplying #{unapply_count} patch(es)"
            elsif apply_count > 0
                package.progress "patching %s: applying #{apply_count} patch(es)"
            else
                package.progress "patching %s: unapplying #{unapply_count} patch(es)"
            end

            while p = cur_patches.last
                unapply(package, p) 
                cur_patches.pop
            end

            patches.to_a.each do |p| 
                apply(package, p) 
                cur_patches << p
	    end
        ensure
            File.open(patchlist(package), 'w+') do |f|
                f.write(cur_patches.join("\n"))
            end
        end

        return true
    end
end
end

