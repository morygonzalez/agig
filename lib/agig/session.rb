require 'ostruct'
require 'time'
require 'net/irc'
require 'octokit'

class Agig::Session < Net::IRC::Server::Session
  def server_name
    "github"
  end

  def server_version
    "0.0.0"
  end

  def channels
    ['#notification', '#watch']
  end

  def initialize(*args)
    super
    @notification_last_retrieved = @watch_last_retrieved = Time.now.utc - 3600
  end

  def client
    @client ||= Octokit::Client.new(login: @nick, password: @pass)
  end

  def on_disconnected
    @retrieve_thread.kill rescue nil
  end

  def on_user(m)
    super

    @real, *@opts = @real.split(/\s+/)
    @opts = OpenStruct.new @opts.inject({}) {|r, i|
      key, value = i.split("=", 2)
      r.update key => case value
                      when nil                      then true
                      when /\A\d+\z/                then value.to_i
                      when /\A(?:\d+\.\d*|\.\d+)\z/ then value.to_f
                      else                               value
                      end
    }
    channels.each{|channel| post @nick, JOIN, channel }

    @retrieve_thread = Thread.start do
      loop do
        begin
          @log.info 'retrieveing feed...'

          entries = client.notifications
          entries.sort_by(&:updated_at).reverse_each do |entry|
            updated_at = Time.parse(entry[:updated_at]).utc
            next if updated_at <= @notification_last_retrieved

            subject = entry['subject']
            post entry['repository']['owner']['login'], PRIVMSG, "#notification", "\0035#{subject['title']}\017 \00314#{subject['latest_comment_url']}\017"
            @notification_last_retrieved = updated_at
          end

          events = client.received_events('hsbt')
          events.sort_by(&:created_at).reverse_each do |event|
            next if event.type != "WatchEvent"

            created_at = Time.parse(event.created_at).utc
            next if created_at <= @watch_last_retrieved

            post event.actor.login, PRIVMSG, "#watch", "\0035#{event.payload.action}\017 \00314http://github.com/#{event.repo.name}\017"
            @watch_last_retrieved = created_at
          end

          @log.info 'sleep'
          sleep 30
        rescue Exception => e
          @log.error e.inspect
          e.backtrace.each do |l|
            @log.error "\t#{l}"
          end
          sleep 10
        end
      end
    end
  end
end
