$:.unshift(File.dirname(__FILE__) + '/../websocket-rack/lib')

require 'sinatra'
require 'json'
require 'fileutils'
require 'rack/websocket'
require 'thread'

class DirectoryHash
  def initialize(path) @mutex = Mutex.new; FileUtils.mkdir_p(@path = path) end
  def keys; files.map {|x| x.sub(/\.html\Z/, '') } end
  def values; files.map {|f| File.read(File.join(@path, f)) } end
  def each(&block) keys.each {|f| yield(f, self[f]) } end
  def delete(key) File.unlink(filename(key)) end
  def [](key) 
    @mutex.synchronize { File.read(filename(key)) }
  rescue Errno::ENOENT
  end
  def []=(key, value)
    @mutex.synchronize do
      File.open(filename(key), 'wb') {|f| f.write value.to_s }
      File.utime(Time.now, Time.now, filename(key))
    end
  end
  def timestamp(key) 
    File.mtime(filename(key)).to_i
  rescue Errno::ENOENT 
  end
  def to_hash; Hash[*keys.map {|k| [k, self[k]] }.flatten] end
  private
  def files; Dir.entries(@path).select {|x| x =~ /\.html\Z/ } end
  def filename(key) File.join(@path, key + '.html') end
end

class GlobalConfig
  class << self
    attr_accessor :clients, :templates, :client_template, :controllers
  end
  
  TEMPLATES_PATH = File.dirname(__FILE__) + '/data/templates'
  CLIENT_INFO_PATH = File.dirname(__FILE__) + '/data/client_info'
  CLIENTS_PATH = File.dirname(__FILE__) + '/data/clients'
  
  @controllers = []
  @clients = []
  @templates = DirectoryHash.new(TEMPLATES_PATH)
  @client_template = DirectoryHash.new(CLIENT_INFO_PATH)
end

class Sinatra::WebSocket < Sinatra::Base
  def self.websocket(*args)
    get(*args) { @handler.call(request.env); 'OK' }
  end

  def on_open(env) end
  def on_message(env, msg) end
  def on_close(env) end
  def on_error(env, error) end

  helpers do
    def send_data(msg) @handler.send_data(msg) end
    def close; @handler.close_websocket end
  end
  
  before do
    return if @handler
    handler_class = Rack::WebSocket::Handler.detect(request.env)
    @handler = handler_class.new(self, {})
  end
end

class ClientScreen < Sinatra::WebSocket
  attr_accessor :client_name
  websocket '/client/:name/connection'

  def on_open(env)
    GlobalConfig.clients |= [self]
    @client_name = params['name']
    @timestamp = 0
    @playing = false
    update
    GlobalConfig.controllers.each(&:update)
  end
  
  def on_error(env, error) on_close(env) end
  def on_close(env)
    GlobalConfig.clients.delete(self) 
    GlobalConfig.controllers.each(&:update)
  end
    
  def update
    if tpl = GlobalConfig.client_template[client_name]
      timestamp = GlobalConfig.templates.timestamp(tpl)
      return if timestamp <= @timestamp && @playing
      @timestamp = timestamp
      @playing = true
      data = {
        'action' => 'play',
        'timestamp' => @timestamp, 
        'templateName' => tpl,
        'template' => GlobalConfig.templates[tpl]
      }
    else
      @playing = false
      data = {'action' => 'stop'}
    end
    puts "#{client_name}: Sending client update... (action=#{data['action']}, template=#{tpl})"
    send_data(data.to_json)
  end
end

class Controller < Sinatra::WebSocket
  websocket '/controller'
  def on_open(env) GlobalConfig.controllers |= [self]; update end
  def on_close(env) GlobalConfig.controllers.delete(self) end

  def update
    data = {
      'clients' => GlobalConfig.clients.map {|c| c.client_name },
      'templates' => GlobalConfig.templates.keys,
      'clientTemplate' => GlobalConfig.client_template.to_hash
    }
    puts "#{object_id}: Sending Controller update... (clients=#{data['clients'].size},templates=#{data['templates'].size})"
    send_data(data.to_json)
  end
end

class MultiDisplay < Sinatra::Base
  set :public, File.dirname(__FILE__) + '/public'
  enable :static
  use ClientScreen
  use Controller
  
  get '/client/:name' do
    erb(:client)
  end

  post '/play/:client/:template' do
    GlobalConfig.client_template[params['client']] = params['template']
    GlobalConfig.controllers.each(&:update)
    update_client(params['client'])
    'OK'
  end
  
  post '/stop/:client' do
    GlobalConfig.client_template.delete(params['client'])
    update_client(params['client'])
    GlobalConfig.controllers.each(&:update)
    'OK'
  end
  
  post '/template' do
    GlobalConfig.templates[params['name']] = params['body']
    GlobalConfig.client_template.each do |client, tpl|
      update_client(client) if tpl == params['name']
    end
    'OK'
  end

  get '/template/:name.json' do
    {'body' => GlobalConfig.templates[params['name']]}.to_json
  end
  
  get '/template' do
    erb(:template)
  end
  
  get '/' do
    erb(:index)
  end
  
  private
  
  def update_client(name)
    puts "Checking which clients to update (match=#{name})"
    GlobalConfig.clients.each do |c| 
      puts "Testing #{c.client_name} == #{name}"
      c.update if c.client_name == name
    end
  end
end
