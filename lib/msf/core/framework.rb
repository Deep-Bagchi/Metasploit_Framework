# -*- coding: binary -*-

#
# Standard Library
#

require 'monitor'

#
# Project
#

require 'metasploit/framework/version'
require 'rex/socket/ssl'
require 'metasploit/framework/thread_factory_provider'
module Msf

###
#
# This class is the primary context that modules, scripts, and user
# interfaces interact with.  It ties everything together.
#
###
class Framework
  include MonitorMixin

  #
  # Versioning information
  #

  Major    = Metasploit::Framework::Version::MAJOR
  Minor    = Metasploit::Framework::Version::MINOR
  Point    = Metasploit::Framework::Version::PATCH
  Release  = "-#{Metasploit::Framework::Version::PRERELEASE}"
  Version  = Metasploit::Framework::VERSION

  Revision = "$Revision$"

  #
  # Mixin meant to be included into all classes that can have instances that
  # should be tied to the framework, such as modules.
  #
  module Offspring

    #
    # A reference to the framework instance from which this offspring was
    # derived.
    #
    attr_accessor :framework
  end

  require 'metasploit/framework/data_service/proxy/core'

  #
  # Creates an instance of the framework context.
  #
  def initialize(options={})
    self.options = options
    # call super to initialize MonitorMixin.  #synchronize won't work without this.
    super()

    # Allow specific module types to be loaded
    types = options[:module_types] || Msf::MODULE_TYPES

    self.events    = EventDispatcher.new(self)
    self.modules   = ModuleManager.new(self,types)
    self.datastore = DataStore.new
    self.jobs      = Rex::JobContainer.new
    self.analyze   = Analyze.new(self)
    self.plugins   = PluginManager.new(self)
    self.browser_profiles = Hash.new
    self.features = FeatureManager.instance

    # Configure the thread factory
    Rex::ThreadFactory.provider = Metasploit::Framework::ThreadFactoryProvider.new(framework: self)

    # Configure the SSL certificate generator
    require 'msf/core/cert_provider'
    Rex::Socket::Ssl.cert_provider = Msf::Ssl::CertProvider

    subscriber = FrameworkEventSubscriber.new(self)
    events.add_exploit_subscriber(subscriber)
    events.add_session_subscriber(subscriber)
    events.add_general_subscriber(subscriber)
    events.add_db_subscriber(subscriber)
    events.add_ui_subscriber(subscriber)
  end

  def inspect
    "#<Framework (#{sessions.length} sessions, #{jobs.length} jobs, #{plugins.length} plugins#{db.active ? ", #{db.driver} database active" : ""})>"
  end

  #
  # Returns the module set for encoders.
  #
  def encoders
    return modules.encoders
  end

  #
  # Returns the module set for exploits.
  #
  def exploits
    return modules.exploits
  end

  #
  # Returns the module set for nops
  #
  def nops
    return modules.nops
  end

  #
  # Returns the module set for payloads
  #
  def payloads
    return modules.payloads
  end

  #
  # Returns the module set for auxiliary modules
  #
  def auxiliary
    return modules.auxiliary
  end

  #
  # Returns the module set for post modules
  #
  def post
    return modules.post
  end

  def evasion
    return modules.evasion
  end

  #
  # Returns the framework version in Major.Minor format.
  #
  def version
    Version
  end

  #
  # Event management interface for registering event handler subscribers and
  # for interacting with the correlation engine.
  #
  attr_reader   :events
  #
  # Module manager that contains information about all loaded modules,
  # regardless of type.
  #
  attr_reader   :modules
  #
  # The global framework datastore that can be used by modules.
  #
  attr_reader   :datastore
  #
  # The framework instance's aux manager.  The aux manager is responsible
  # for collecting and cataloging all aux information that comes in from
  # aux modules.
  #
  attr_reader   :auxmgr
  #
  # Background job management specific to things spawned from this instance
  # of the framework.
  #
  attr_reader   :jobs
  #
  # The framework instance's plugin manager.  The plugin manager is
  # responsible for exposing an interface that allows for the loading and
  # unloading of plugins.
  #
  attr_reader   :plugins
  #
  # The framework instance's browser profile store. These profiles are
  # generated by client-side modules and need to be shared across
  # different contexts.
  #
  attr_reader   :browser_profiles
  #
  # The framework instance's analysis utility.  Provide method to analyze
  # framework objects to offer related objects/actions available.
  #
  attr_reader   :analyze
  #
  # The framework instance's feature manager. The feature manager is responsible
  # for configuring feature flags that can change characteristics of framework.
  #
  attr_reader   :features


  #
  # The framework instance's data service proxy
  #
  # @return [Metasploit::Framework::DataService::DataProxy]
  def db
    synchronize {
      @db ||= get_db
    }
  end

  # Session manager that tracks sessions associated with this framework
  # instance over the course of their lifetime.
  #
  # @return [Msf::SessionManager]
  def sessions
    synchronize {
      @sessions ||= Msf::SessionManager.new(self)
    }
  end

  # The framework instance's thread manager. The thread manager
  # provides a cleaner way to manage spawned threads
  #
  # @return [Msf::ThreadManager]
  def threads
    synchronize {
      @threads ||= Msf::ThreadManager.new(self)
    }
  end

  # Whether {#threads} has been initialized
  #
  # @return [true] if {#threads} has been initialized
  # @return [false] otherwise
  def threads?
    synchronize {
      instance_variable_defined? :@threads
    }
  end

  def search(search_string)
    search_params = Msf::Modules::Metadata::Search.parse_search_string(search_string)
    Msf::Modules::Metadata::Cache.instance.find(search_params)
  end

  #
  # EICAR Canary
  # @return [Boolean] Should return true if the EICAR file has been corrupted
  def eicar_corrupted?
    path = ::File.expand_path(::File.join(
      ::File.dirname(__FILE__),"..", "..", "..", "data", "eicar.com")
    )
    return true unless ::File.exist?(path)

    data = ::File.read(path)
    return true unless Digest::SHA1.hexdigest(data) == "3395856ce81f2b7382dee72602f798b642f14140"

    false

  # If anything goes wrong assume AV got us
  rescue ::Exception
    true
  end

protected

  # @!attribute options
  #   Options passed to {#initialize}
  #
  #   @return [Hash]
  attr_accessor :options

  attr_writer   :events # :nodoc:
  attr_writer   :modules # :nodoc:
  attr_writer   :datastore # :nodoc:
  attr_writer   :auxmgr # :nodoc:
  attr_writer   :jobs # :nodoc:
  attr_writer   :plugins # :nodoc:
  attr_writer   :db # :nodoc:
  attr_writer   :browser_profiles # :nodoc:
  attr_writer   :analyze # :nodoc:
  attr_writer   :features # :nodoc:

  private

  def get_db
    unless options['DisableDatabase']
      db_manager = Msf::DBManager.new(self)
      options[:db_manager] = db_manager
      unless options['SkipDatabaseInit']
        db_manager.init_db(options)
      end
    end

    Metasploit::Framework::DataService::DataProxy.new(options)
  end

end

class FrameworkEventSubscriber
  include Framework::Offspring
  def initialize(framework)
    self.framework = framework
  end

  def report_event(data)
    if framework.db.active
      framework.db.report_event(data)
    end
  end

  include Msf::GeneralEventSubscriber

  #
  # Generic handler for module events
  #
  def module_event(name, instance, opts={})
    if framework.db.active
      event = {
        :workspace => framework.db.find_workspace(instance.workspace),
        :name      => name,
        :username  => instance.owner,
        :info => {
          :module_name => instance.fullname,
          :module_uuid => instance.uuid
        }.merge(opts)
      }

      report_event(event)
    end
  end

  ##
  # :category: ::Msf::GeneralEventSubscriber implementors
  def on_module_run(instance)
    opts = { :datastore => instance.datastore.to_h }
    module_event('module_run', instance, opts)
  end

  ##
  # :category: ::Msf::GeneralEventSubscriber implementors
  def on_module_complete(instance)
    module_event('module_complete', instance)
  end

  ##
  # :category: ::Msf::GeneralEventSubscriber implementors
  def on_module_error(instance, exception=nil)
    module_event('module_error', instance, :exception => exception.to_s)
  end

  include ::Msf::UiEventSubscriber
  ##
  # :category: ::Msf::UiEventSubscriber implementors
  def on_ui_command(command)
    if (framework.db and framework.db.active)
      report_event(:name => "ui_command", :info => {:command => command})
    end
  end

  ##
  # :category: ::Msf::UiEventSubscriber implementors
  def on_ui_stop()
    if (framework.db and framework.db.active)
      report_event(:name => "ui_stop")
    end
  end

  ##
  # :category: ::Msf::UiEventSubscriber implementors
  def on_ui_start(rev)
    #
    # The database is not active at startup time unless msfconsole was
    # started with a database.yml, so this event won't always be saved to
    # the db.  Not great, but best we can do.
    #
    info = { :revision => rev }
    report_event(:name => "ui_start", :info => info)
  end


  include ::Msf::SessionEvent

  #
  # Generic handler for session events
  #
  def session_event(name, session, opts={})
    address = session.session_host

    if not (address and address.length > 0)
      elog("Session with no session_host/target_host/tunnel_peer. Session Info: #{session.inspect}")
      return
    end

    if framework.db.active
      ws = framework.db.find_workspace(session.workspace)
      opts.each_key do |attr|
        opts[attr].force_encoding('UTF-8') if opts[attr].is_a?(String)
      end

      event = {
        :workspace => ws,
        :username  => session.username,
        :name => name,
        :host => address,
        :info => {
          :session_id   => session.sid,
          :session_info => session.info,
          :session_uuid => session.uuid,
          :session_type => session.type,
          :username     => session.username,
          :target_host  => address,
          :via_exploit  => session.via_exploit,
          :via_payload  => session.via_payload,
          :tunnel_peer  => session.tunnel_peer,
          :exploit_uuid => session.exploit_uuid
        }.merge(opts)
      }
      report_event(event)
    end
  end


  ##
  # :category: ::Msf::SessionEvent implementors
  def on_session_open(session)
    opts = { :datastore => session.exploit_datastore.to_h, :critical => true }
    session_event('session_open', session, opts)
    framework.db.report_session(:session => session)
  end

  ##
  # :category: ::Msf::SessionEvent implementors
  def on_session_upload(session, lpath, rpath)
    session_event('session_upload', session, :local_path => lpath, :remote_path => rpath)
    framework.db.report_session_event({
      :etype => 'upload',
      :session => session,
      :local_path => lpath,
      :remote_path => rpath
    })
  end
  ##
  # :category: ::Msf::SessionEvent implementors
  def on_session_download(session, rpath, lpath)
    session_event('session_download', session, :local_path => lpath, :remote_path => rpath)
    framework.db.report_session_event({
      :etype => 'download',
      :session => session,
      :local_path => lpath,
      :remote_path => rpath
    })
  end

  ##
  # :category: ::Msf::SessionEvent implementors
  def on_session_close(session, reason='')
    session_event('session_close', session)
    if session.db_record
      # Don't bother saving here, the session's cleanup method will take
      # care of that later.
      session.db_record.close_reason = reason
      session.db_record.closed_at = Time.now.utc
    end
  end

  #def on_session_interact(session)
  #	$stdout.puts('session_interact', session.inspect)
  #end

  ##
  # :category: ::Msf::SessionEvent implementors
  def on_session_command(session, command)
    session_event('session_command', session, :command => command)
    framework.db.report_session_event({
      :etype => 'command',
      :session => session,
      :command => command
    })
  end

  ##
  # :category: ::Msf::SessionEvent implementors
  def on_session_output(session, output)
    # Break up the output into chunks that will fit into the database.
    buff = output.dup
    chunks = []
    if buff.length > 1024
      while buff.length > 0
        chunks << buff.slice!(0,1024)
      end
    else
      chunks << buff
    end
    chunks.each { |chunk|
      session_event('session_output', session, :output => chunk)
      framework.db.report_session_event({
        :etype => 'output',
        :session => session,
        :output => chunk
      })
    }
  end

  ##
  # :category: ::Msf::SessionEvent implementors
  def on_session_route(session, route)
    framework.db.report_session_route({session: session, route: route})
  end

  ##
  # :category: ::Msf::SessionEvent implementors
  def on_session_route_remove(session, route)
    framework.db.report_session_route_remove({session: session, route: route})
  end

  ##
  # :category: ::Msf::SessionEvent implementors
  def on_session_script_run(session, script)
    framework.db.report_session_event({
      :etype => 'script_run',
      :session => session,
      :local_path => script
    })
  end

  ##
  # :category: ::Msf::SessionEvent implementors
  def on_session_module_run(session, mod)
    framework.db.report_session_event({
      :etype => 'module_run',
      :session => session,
      :local_path => mod.fullname
    })
  end

  #
  # This is covered by on_module_run and on_session_open, so don't bother
  #
  #include ExploitEvent
  #def on_exploit_success(exploit, session)
  #end

end
end
