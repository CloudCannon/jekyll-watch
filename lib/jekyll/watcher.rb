# frozen_string_literal: true

require "listen"

module Jekyll
  module Watcher
    extend self

    # Public: Continuously watch for file changes and rebuild the site
    # whenever a change is detected.
    #
    # If the optional site argument is populated, that site instance will be
    # reused and the options Hash ignored. Otherwise, a new site instance will
    # be instantiated from the options Hash and used.
    #
    # options - A Hash containing the site configuration
    # site    - The current site instance (populated starting with Jekyll 3.2)
    #           (optional, default: nil)
    #
    # Returns nothing.
    def watch(options, site = nil)
      ENV["LISTEN_GEM_DEBUGGING"] ||= "1" if options["verbose"]

      site ||= Jekyll::Site.new(options)
      listener_paths = listen_source_paths(site, options)
      listener = build_listener(site, options, listener_paths)
      listener.start

      Jekyll.logger.info "Auto-regeneration:", "enabled for"
      listener_paths.map do |path|
        Jekyll.logger.info "", "#{path}"
      end

      unless options["serving"]
        trap("INT") do
          listener.stop
          Jekyll.logger.info "", "Halting auto-regeneration."
          exit 0
        end

        sleep_forever
      end
    rescue ThreadError
      # You pressed Ctrl-C, oh my!
    end

    private

    def build_listener(site, options, listener_paths)
      Listen.to(
        *listener_paths,
        :ignore        => listen_ignore_paths(options),
        :force_polling => options["force_polling"],
        &listen_handler(site)
      )
    end

    def listen_handler(site)
      proc do |modified, added, removed|
        t = Time.now
        c = modified + added + removed
        n = c.length

        Jekyll.logger.info "Regenerating:",
                           "#{n} file(s) changed at #{t.strftime("%Y-%m-%d %H:%M:%S")}"

        c.each { |path| Jekyll.logger.info "", path["#{site.source}/".length..-1] }
        process(site, t)
      end
    end

    def normalize_encoding(obj, desired_encoding)
      case obj
      when Array
        obj.map { |entry| entry.encode!(desired_encoding, entry.encoding) }
      when String
        obj.encode!(desired_encoding, obj.encoding)
      end
    end

    def custom_excludes(options)
      Array(options["exclude"]).map { |e| Jekyll.sanitized_path(options["source"], e) }
    end

    def config_files(options)
      %w(yml yaml toml).map do |ext|
        Jekyll.sanitized_path(options["source"], "_config.#{ext}")
      end
    end

    def to_exclude(options)
      [
        config_files(options),
        options["destination"],
        custom_excludes(options),
      ].flatten
    end

    def listen_source_paths(site, options)
      [
        options["source"],
        options["watch_dirs"],
        site&.config["watch_dirs"],
        find_theme_path(site),
      ].flatten.delete_if(&:nil?)
    end

    def find_theme_path(site)
      unless site.theme&.root
        Jekyll.logger.info "Locating Theme:", "No theme found to watch"
        return
      end
      if site.theme.root.include? ".gem" or site.theme.root.include? "vendor"
        Jekyll.logger.info "Locating Theme:", "Theme not local, skipping watch ❌"
        Jekyll.logger.info "", "Run `bundle config local.#{site.theme.name} ~/path/to/theme` for local dev"
        return
      end
      Jekyll.logger.info "Locating Theme:", "Local theme found ✅"
      site.theme.root
    end

    # Paths to ignore for the watch option
    #
    # options - A Hash of options passed to the command
    #
    # Returns a list of relative paths from source that should be ignored
    def listen_ignore_paths(options)
      source = Pathname.new(options["source"]).expand_path
      paths  = to_exclude(options)

      paths.map do |p|
        absolute_path = Pathname.new(normalize_encoding(p, options["source"].encoding)).expand_path
        next unless absolute_path.exist?

        begin
          relative_path = absolute_path.relative_path_from(source).to_s
          relative_path = File.join(relative_path, "") if absolute_path.directory?
          unless relative_path.start_with?("../")
            path_to_ignore = %r!^#{Regexp.escape(relative_path)}!
            Jekyll.logger.debug "Watcher:", "Ignoring #{path_to_ignore}"
            path_to_ignore
          end
        rescue ArgumentError
          # Could not find a relative path
        end
      end.compact + [%r!^\.jekyll\-metadata!]
    end

    def sleep_forever
      loop { sleep 1000 }
    end

    def process(site, time)
      begin
        site.process
        Jekyll.logger.info "", "...done in #{Time.now - time} seconds."
      rescue StandardError => e
        Jekyll.logger.warn "Error:", e.message
        Jekyll.logger.warn "Error:", "Run jekyll build --trace for more information."
      end
      Jekyll.logger.info ""
    end
  end
end
