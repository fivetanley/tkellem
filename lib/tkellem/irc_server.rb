require 'set'
require 'eventmachine'
require 'tkellem/irc_message'
require 'tkellem/bouncer_connection'
require 'tkellem/backlog'

module Tkellem

class IrcServer
  attr_reader :name, :welcomes, :rooms, :nick, :active_conns
  alias_method :log_name, :name
  include Tkellem::EasyLogger

  def initialize(bouncer, name, nick)
    @bouncer = bouncer
    @name = name
    @nick = nick
    @cur_host = -1
    @hosts = []

    @connected = false
    @max_backlog = nil
    @backlogs = {}
    @push_services = {}

    @welcomes = []
    @rooms = Set.new
    @active_conns = []
    @joined_rooms = false
    # maps { bouncer_conn => away_status_or_nil }
    @away = {}
  end

  def connected?
    @connected
  end

  def add_host(host, port, do_ssl)
    @hosts << [host, port, do_ssl]
    connect! if @hosts.length == 1
  end

  def set_max_backlog(max_backlog)
    @max_backlog = max_backlog
    @backlogs.each { |name, backlog| backlog.max_backlog = max_backlog }
  end

  def join_room(room)
    @rooms << room
    if connected?
      send_msg("JOIN #{room_name}")
    end
  end

  def add_client(name)
    return if @backlogs[name]
    backlog = Backlog.new(name, @max_backlog)
    @backlogs[name] = backlog
  end

  def disconnected!
    @conn = nil
    @connected = false
    @backlogs.keys.each { |name| remove_client(name) }
    connect!
  end

  def connection_established
    # TODO: support sending a real username, realname, etc
    send_msg("USER #{nick} localhost blah :#{nick}")
    change_nick(nick, true)
  end

  def receive_line(line)
    trace "from server: #{line}"
    msg = IrcMessage.parse(line)

    case msg.command
    when /0\d\d/, /2[56]\d/, /37[256]/
      welcomes << msg
      got_welcome if msg.command == "376" # end of MOTD
    when /join/i
      debug "#{msg.target_user} joined #{msg.args.last}"
      rooms << msg.args.last if msg.target_user == nick
    when /part/i
      debug "#{msg.target_user} left #{msg.args.last}"
      rooms.delete(msg.args.last) if msg.target_user == nick
    when /ping/i
      send_msg("PONG #{nick}!tkellem :#{msg.args.last}")
    when /pong/i
      # swallow it, we handle ping-pong from clients separately, in
      # BouncerConnection
    else
    end

    @backlogs.each { |name, backlog| backlog.handle_message(msg) }
    @push_services.each { |k, service| service.handle_message(msg) }
  end

  def got_welcome
    return if @joined_rooms
    @joined_rooms = true
    rooms.each do |room|
      join_room(room)
    end

    # We're all initialized, allow connections
    @connected = true
    check_away_status
  end

  def got_away(bouncer_conn, msg)
    @away[bouncer_conn] = msg.args.last
    check_away_status
  end

  def change_nick(new_nick, force = false)
    return if !force && new_nick == @nick
    @nick = new_nick
    send_msg("NICK #{new_nick}")
  end

  def remove_client(name)
    backlog = @backlogs[name]
    if backlog
      backlog.active_conns.each do |conn|
        conn.error!("client disconnected")
      end
    end
  end

  def send_msg(msg)
    trace "to server: #{msg}"
    @conn.send_data("#{msg}\r\n")
  end

  def send_welcome(bouncer_conn)
    welcomes.each { |msg| bouncer_conn.send_msg(msg) }
  end

  def bouncer_connect(bouncer_conn)
    return nil unless @backlogs[bouncer_conn.name]

    active_conns << bouncer_conn
    @backlogs[bouncer_conn.name].add_conn(bouncer_conn)
    @away[bouncer_conn] = nil
    check_away_status
    @backlogs[bouncer_conn.name]
  end

  def bouncer_disconnect(bouncer_conn)
    return nil unless @backlogs[bouncer_conn.name]

    @backlogs[bouncer_conn.name].remove_conn(bouncer_conn)
    @away.delete(bouncer_conn)
    check_away_status
    active_conns.delete(bouncer_conn)
  end

  def check_away_status
    # for now we pretty much randomly pick an away status if multiple are set
    # by clients
    if @away.any? { |k,v| !v }
      # we have a client who isn't away
      send_msg("AWAY")
    else
      message = @away.values.first || "Away"
      send_msg("AWAY :#{message}")
    end
  end

  def got_push(bouncer_conn, msg)
    if msg.args.first != 'add-device'
      info "got PUSH but it's not add-device and we don't have a push service yet"
      return nil
    end
    service = PushService.new(self, msg)
    @push_services[service.device_token] = service
    service
  end

  protected

  def connect!
    span = @last_connect ? Time.now - @last_connect : 1000
    if span < 5
      EM.add_timer(5) { connect! }
      return
    end
    @last_connect = Time.now
    @cur_host += 1
    @cur_host = @cur_host % @hosts.length
    host = @hosts[@cur_host]
    @conn = EM.connect(host[0], host[1], IrcServerConnection, self, host[2])
  end
end

module IrcServerConnection
  include EM::Protocols::LineText2
  include Tkellem::EasyLogger

  def initialize(irc_server, do_ssl)
    set_delimiter "\r\n"

    @irc_server = irc_server
    @ssl = do_ssl
    @connected = false
  end

  def connected?
    @connected
  end

  def post_init
    if @ssl
      @irc_server.debug "starting TLS"
      # TODO: support strict cert checks
      start_tls :verify_peer => false
    else
      ssl_handshake_completed
    end
  end

  def ssl_handshake_completed
    @connected = true
    EM.next_tick { @irc_server.connection_established }
  end

  def receive_line(line)
    @irc_server.receive_line(line)
  end

  def unbind
    @irc_server.debug "OMG we got disconnected."
    @irc_server.disconnected!
  end
end

end
