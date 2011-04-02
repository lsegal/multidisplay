require 'sinatra'
require 'json'
require 'fileutils'

class DirectoryHash
  def initialize(path)
    FileUtils.mkdir_p(path)
    @path = path
  end
  
  def keys
    files.map {|x| x.sub(/\.html\Z/, '') }
  end
  
  def values
    files.map {|f| File.read(File.join(@path, f)) }
  end
  
  def each(&block)
    files.each {|f| yield(f, self[f]) }
  end
  
  def delete(key)
    File.unlink(filename(key))
  end
  
  def [](key)
    File.read(filename(key))
  rescue Errno::ENOENT
  end
  
  def []=(key, value)
    File.open(filename(key), 'wb') {|f| f.write value.to_s }
    File.utime(Time.now, Time.now, filename(key))
  end
  
  def timestamp(key)
    File.mtime(filename(key)).to_i
  rescue Errno::ENOENT
  end
  
  private
  
  def files
    Dir.entries(@path).select {|x| x =~ /\.html\Z/ }
  end
  
  def filename(key)
    File.join(@path, key + '.html')
  end
end

class MemoryHash < Hash
  def initialize(*args)
    super
    @timestamps = {}
  end
  
  def []=(k, v) @timestamps[k] = Time.now.to_i; super end
  def timestamp(key) @timestamps[k] end
end

class MultiDisplay < Sinatra::Base
  set :public, File.dirname(__FILE__) + '/public'
  enable :static
  
  def initialize(*args)
    super
    @clients = DirectoryHash.new(CLIENTS_PATH)
    @templates = DirectoryHash.new(TEMPLATES_PATH)
    @client_template = DirectoryHash.new(CLIENT_INFO_PATH)
  end
  
  get '/connect/:name' do
    @clients[params['name']] ||= 0
    v = @clients[params['name']].to_i + 1
    @clients[params['name']] = v
    @template = {:name => @client_template[params['name']]}
    if @template[:name].nil?
      @template[:name] = "None"
      @template[:body] = "Loading..."
      @template[:update_time] = 0
    else
      @template[:body] = @templates[@template[:name]]
      @template[:update_time] = @templates.timestamp(@template[:name])
    end
    erb(:view)
  end
  
  get '/client/:name' do
    content_type 'text/json'
    tpl = @client_template[params['name']]
    halt 404 if tpl.nil?
    {'timestamp' => @templates.timestamp(tpl), 
      'templateName' => tpl,
      'template' => @templates[tpl]}.to_json
  end
  
  get '/view/:template' do
    content_type 'text/json'
    {'timestamp' => @templates.timestamp(params['template']), 
      'template' => @templates[params['template']]}.to_json
  end
  
  get '/disconnect/:name' do
    @clients[params['name']] ||= 0
    v = @clients[params['name']].to_i - 1
    if v <= 0
      @clients.delete(params['name'])
    else
      @clients[params['name']] = v
    end
  end
  
  post '/play/:client/:template' do
    @client_template[params['client']] = params['template']
  end
  
  post '/stop/:client' do
    @client_template.delete(params['client'])
  end
  
  post '/template' do
    @templates[params['name']] = params['body']
  end
  
  get '/template' do
    erb(:template)
  end
  
  get '/' do
    erb(:index)
  end
  
  private
  
  DUMP_FILENAME = File.dirname(__FILE__) + '/app.dump'
  TEMPLATES_PATH = File.dirname(__FILE__) + '/data/templates'
  CLIENT_INFO_PATH = File.dirname(__FILE__) + '/data/client_info'
  CLIENTS_PATH = File.dirname(__FILE__) + '/data/clients'
end