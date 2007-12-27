require 'net/http'
require 'logger'
require 'singleton'

# from Common
require 'seldon/stats'
require 'seldon/agent/worker_loop'
require 'seldon/agent_messages'

# from Agent
require 'seldon/agent/stats_engine'
require 'seldon/agent/transaction_sampler'

# if Mongrel isn't present, we still need a class declaration
module Mongrel
  class HttpServer; end
end

# The Seldon Agent collects performance data from rails applications in realtime as the
# application runs, and periodically sends that data to the Seldon server.  
module Seldon::Agent
  # add some convenience methods for easy access to the Agent singleton.
  # the following static methods all point to the same Agent instance:
  #
  # Seldon::Agent.agent
  # Seldon::Agent.instance
  # Seldon::Agent::Agent.instance
  class << self
    def agent
      Seldon::Agent::Agent.instance
    end
    
    alias instance agent

    # Get or create a statistics gatherer that will aggregate numerical data
    # under a metric name.
    #
    # metric_name should follow a slash separated path convention.  Application
    # specific metrics should begin with "Custom/".
    #
    # the statistical gatherer returned by get_stats accepts data
    # via calls to add_data_point(value)
    def get_stats(metric_name)
      unless metric_name =~ /Custom\// 
        raise Exception.new("Invalid Name for Application Custom Metric: #{metric_name}")
      end
      agent.stats_engine.get_stats(metric_name, false)
    end
  end
  
  # Implementation defail for the Seldon Agent
  class Agent
    include Singleton
    
    DEFAULT_HOST = 'localhost'
    DEFAULT_PORT = 3000
    
    attr_reader :stats_engine
    attr_reader :transaction_sampler
    attr_reader :worker_loop
    attr_reader :log
    
    # Start up the agent, which will connect to the seldon server and start 
    # reporting performance information.  Typically this is done from the
    # environment configuration file
    def start(config)
      if @started
        log.error "Agent Started Already!"
        raise Exception.new("Duplicate attempt to start the Seldon agent")
      end
      
      # set the log level as specified in the config file
      case config.fetch("log_level","info").downcase
        when "debug": @log.level = Logger::DEBUG
        when "info": @log.level = Logger::INFO
        when "warn": @log.level = Logger::WARN
        when "error": @log.level = Logger::ERROR
        when "fatal": @log.level = Logger::FATAL
        else @log.level = Logger::INFO
      end
    
      @started = true
      
      @remote_host = config.fetch('host', '310new.pascal.hostingrails.com')
      @remote_port = config.fetch('port', '80')
      
      # add tasks to the worker loop.
      # TODO figure out how we configure reporting frequency.  Should be Server based to 
      # prevent hackers from flooding the server with metric data
      @worker_loop.add_task(30.0) do 
        harvest_and_send_timeslice_data
      end
      @worker_loop.add_task(15.0) do
        harvest_and_send_sample_data
      end
      
      # disabling ping - we don't use callbacks and therefore don't need it, and
      # it's the number one CPU hog on the server
      @worker_loop.add_task(5.0) do
        ping
      end if false
      
      @worker_thread = Thread.new do 
        run_worker_loop
      end
    end
  
    private
      def initialize
        @my_port = determine_port
        @my_host = determine_host
        
        @log = Logger.new "#{RAILS_ROOT}/log/seldon_agent.#{@my_port}.log"
        @log.level = Logger::INFO
        
        @connected = false
        @launch_time = Time.now
       
        @worker_loop = WorkerLoop.new(@log)
        
        @metric_ids = {}
        
        @stats_engine = StatsEngine.new(@log)
        @transaction_sampler = TransactionSampler.new(self)
        
        log.info "\n\nSeldon Agent Initialized: pid = #{$$}"
      end
      
      def connect
        begin
          # wait a few seconds for the web server to boot
          sleep 5
          
          @agent_id = invoke_remote :launch, @my_host,
            @my_port, determine_home_directory, $$, @launch_time
          
          log.info "Connecting to Seldon Service at #{@remote_host}:#{@remote_port}.  Agent ID = #{@agent_id}."
          
          # an agent id of 0 indicates an error occurring on the server
          # TODO after some number of failures, stop trying to connect...
          if (@agent_id && @agent_id > 0)
            @connected = true
            @last_harvest_time = Time.now
          end
        rescue Exception => e
          log.error "error attempting to connect: #{$!}"
          log.error e.backtrace.join("\n")
        end
      end
    
      # this loop will run forever on its own thread, reporting data to the 
      # server
      def run_worker_loop
        # attempt to connect to the server
        until @connected
          connect
        end
        
        @worker_loop.run
      end
    
      def determine_host
        Socket.gethostname
      end
      
      def determine_port
        # TODO I would like to make this nil, but that fails in XMLRPC.  Blegh.
        port = -1
        
        # OPTIONS is set by script/server
        port = OPTIONS.fetch :port, DEFAULT_PORT
      rescue NameError => e
        # this case covers starting by mongrel_rails
        # TODO review this approach.  There should be only one http server
        # allocated in a given rails process...
        ObjectSpace.each_object(Mongrel::HttpServer) do |mongrel|
          port = mongrel.port
        end
      rescue NameError => e
        log.info "Could not determine port.  Likely running as a cgi"
      ensure
        return port
      end
      
      def determine_home_directory
        File.expand_path(RAILS_ROOT)
      end
      
      @last_harvest_time = Time.now
      def harvest_and_send_timeslice_data
        now = Time.now
        @unsent_timeslice_data ||= {}
        @unsent_timeslice_data = @stats_engine.harvest_timeslice_data(@unsent_timeslice_data, @metric_ids)
        
        metric_ids = invoke_remote :metric_data, @agent_id, 
                  @last_harvest_time.to_f, 
                  now.to_f, 
                  @unsent_timeslice_data.values
        @metric_ids.merge! metric_ids
        
        log.debug "#{Time.now}: sent #{@unsent_timeslice_data.length} timeslices (#{@agent_id})"

        # if we successfully invoked this web service, then clear the unsent message cache.
        @unsent_timeslice_data.clear
        @last_harvest_time = Time.now
        
        # handle_messages messages
      rescue Exception => e
        puts e
        puts e.backtrace[0..6].join("\n")
      end

      def harvest_and_send_sample_data
        @unsent_samples ||= []
        @unsent_samples = @transaction_sampler.harvest_samples(@unsent_samples)
        
        # limit the sample data to 100 elements, to prevent server flooding
        @unsent_samples = @unsent_samples[0..100] if @unsent_samples.length > 100
        
        # avoid the webservice call if there is no data to send
        if @unsent_samples.length > 0
          sample_data = []
          @unsent_samples.each do |sample|
            sample_data.push Marshal.dump(sample)
          end
          
          messages = @agent_listener_service.transaction_sample_data @agent_id, sample_data
        
          # if we successfully invoked the web service, then clear the unsent sample cache
          @unsent_samples.clear
          handle_messages messages
        end
      end

      def ping
        messages = @agent_listener_service.ping @agent_id
        handle_messages messages
      end
      
      def handle_messages(messages)
        messages.each do |message|
          begin
            message = Marshal.load(message)
            message.execute(self)
            log.debug("Received Message: #{message.to_yaml}")
          rescue Exception => e
            log.error "Error handling message: #{e}"
            log.debug e.backtrace.join("\n")
          end
        end
      end
      
      # send a message via post
      def invoke_remote(method, *args)
        post_data = [method, args]
        post_data = CGI::escape(Marshal.dump(post_data))

        res = Net::HTTP.start(@remote_host, @remote_port) do |http|
          http.post('/agent_listener/invoke_raw_method', post_data) 
        end

        return Marshal.load(CGI::unescape(res.body))
      rescue Exception => e
        log.error("Error communicating with server: #{e}")
        log.error(e.backtrace[0..7].join("\n"))
        return nil
      end
  end

end

# sampler for CPU Time
module Seldon::Agent
  class CPUSampler
    def initialize
      t = Process.times
      @last_utime = t.utime
      @last_stime = t.stime
  
      agent = Seldon::Agent.instance
  
      agent.stats_engine.add_sampled_metric("CPU/User Time") do | stats |
        utime = Process.times.utime
        stats.record_data_point utime - @last_utime
        @last_utime = utime
      end
  
      agent.stats_engine.add_sampled_metric("CPU/System Time") do | stats |
        stime = Process.times.stime
        stats.record_data_point stime - @last_stime
        @last_stime = stime
      end
    end
  end
end

Seldon::Agent::CPUSampler.new