# route.rb
require 'sinatra'
require 'sinatra/contrib'
require 'json'
require 'securerandom'
require 'net/http'
require 'uri'
require 'openssl'
require 'base64'
require 'time'
require 'sqlite3'
require 'bcrypt'
require 'chunky_png'

# ─── Load all source files ───
require_relative 'src/db'
require_relative 'src/signin'
require_relative 'src/api'
require_relative 'src/graph'

# ─── Configuration ───
configure do
  enable :sessions
  set :session_secret, ENV.fetch('SESSION_SECRET') { SecureRandom.hex(64) }
  set :views, File.dirname(__FILE__) + '/views'
  set :public_folder, File.dirname(__FILE__) + '/public'
  
  # X OAuth2 credentials (set these as environment variables)
  set :x_client_id, ENV['X_CLIENT_ID']
  set :x_client_secret, ENV['X_CLIENT_SECRET']
  set :x_redirect_uri, ENV['X_REDIRECT_URI'] || 'http://localhost:4567/auth/x/callback'
end

# ─── Home Route ───
get '/' do
  if session[:user_id]
    redirect '/dashboard'
  else
    erb :home
  end
end

# ─── Sign In Page ───
get '/signin' do
  if session[:user_id]
    redirect '/dashboard'
  else
    erb :signin
  end
end

# ─── Sign Up Page ───
get '/signup' do
  if session[:user_id]
    redirect '/dashboard'
  else
    erb :signup
  end
end

# ─── Email Sign Up ───
post '/signup' do
  content_type :json
  
  request.body.rewind
  data = JSON.parse(request.body.read) rescue {}
  email = data['email'].to_s.strip
  
  unless valid_email?(email)
    status 400
    return { error: 'Invalid email format' }.to_json
  end
  
  if DB.user_exists?(email)
    status 409
    return { error: 'Email already registered' }.to_json
  end
  
  password = generate_password
  password_hash = hash_password(password)
  confirmation_token = SecureRandom.hex(32)
  
  DB.create_unconfirmed_user(email, password_hash, confirmation_token)
  
  {
    status: 'ok',
    message: 'Account created. Please save your password and confirm.',
    password: password
  }.to_json
end

# ─── Email Confirm ───
post '/confirm' do
  content_type :json
  
  request.body.rewind
  data = JSON.parse(request.body.read) rescue {}
  email = data['email'].to_s.strip
  token = data['token'].to_s.strip
  
  user = DB.find_unconfirmed_user(email, token)
  
  if user.nil?
    status 404
    return { error: 'Invalid confirmation link or already confirmed' }.to_json
  end
  
  DB.confirm_user(email)
  
  {
    status: 'ok',
    message: 'Email confirmed successfully. You can now log in.'
  }.to_json
end

# ─── Email Login ───
post '/login' do
  content_type :json
  
  request.body.rewind
  data = JSON.parse(request.body.read) rescue {}
  email = data['email'].to_s.strip
  password = data['password'].to_s
  
  user = DB.find_user_by_email(email)
  
  if user.nil?
    status 401
    return { error: 'Invalid email or password' }.to_json
  end
  
  unless user[:confirmed]
    status 403
    return { error: 'Please confirm your email first' }.to_json
  end
  
  unless verify_password(password, user[:password_hash])
    status 401
    return { error: 'Invalid email or password' }.to_json
  end
  
  session[:user_id] = user[:id]
  session[:email] = user[:email]
  
  {
    status: 'ok',
    message: 'Logged in successfully',
    redirect: '/dashboard'
  }.to_json
end

# ─── Logout ───
post '/logout' do
  session.clear
  { status: 'ok', message: 'Logged out' }.to_json
end

# ─── Dashboard ───
get '/dashboard' do
  unless session[:user_id]
    redirect '/signin'
  end
  
  @user = DB.find_user_by_id(session[:user_id])
  
  if @user.nil?
    session.clear
    redirect '/signin'
  end
  
  erb :dashboard
end

# ─── Configure Social Platforms ───
post '/api/configure' do
  content_type :json
  
  unless session[:user_id]
    status 401
    return { error: 'Not logged in' }.to_json
  end
  
  request.body.rewind
  data = JSON.parse(request.body.read) rescue {}
  
  devto = data['devto'].to_s.strip
  youtube = data['youtube'].to_s.strip
  github = data['github'].to_s.strip
  
  DB.save_social_config(session[:user_id], devto, youtube, github)
  
  # Fetch dev.to stats if provided
  if !devto.empty?
    devto_stats = SocialFetcher.fetch_devto(devto)
    if devto_stats && !devto_stats[:error]
      DB.save_cached_stats(session[:user_id], 'devto', devto_stats[:followers])
    end
  end
  
  # Fetch GitHub stats if provided
  if !github.empty?
    github_stats = SocialFetcher.fetch_github(github)
    if github_stats && !github_stats[:error]
      DB.save_cached_stats(session[:user_id], 'github', github_stats[:followers])
    end
  end
  
  # YouTube will be fetched on-demand via the API
  
  {
    status: 'ok',
    message: 'Configuration saved successfully'
  }.to_json
end

# ─── Get Graph ───
get '/graph' do
  content_type :json
  
  unless session[:user_id]
    status 401
    return { error: 'Not logged in' }.to_json
  end
  
  user = DB.find_user_by_id(session[:user_id])
  
  if user.nil?
    session.clear
    status 401
    return { error: 'Session invalid' }.to_json
  end
  
  # Build data from DB
  data = {}
  
  # X stats
  if user[:followers] > 0
    data[:x] = {
      value: user[:followers],
      label: 'X'
    }
  end
  
  # Get cached stats for other platforms
  devto_stats = DB.get_cached_stats(user[:id], 'devto')
  if devto_stats && devto_stats[:followers] > 0
    data[:devto] = {
      value: devto_stats[:followers],
      label: 'dev.to'
    }
  end
  
  youtube_stats = DB.get_cached_stats(user[:id], 'youtube')
  if youtube_stats && youtube_stats[:followers] > 0
    data[:youtube] = {
      value: youtube_stats[:followers],
      label: 'YouTube'
    }
  end
  
  github_stats = DB.get_cached_stats(user[:id], 'github')
  if github_stats && github_stats[:followers] > 0
    data[:github] = {
      value: github_stats[:followers],
      label: 'GitHub'
    }
  end
  
  if data.empty?
    status 404
    return { error: 'No data available to generate graph' }.to_json
  end
  
  # Get parameters
  graph_type = params['type'] || 'bar'
  width = params['width'] ? params['width'].to_i : 800
  height = params['height'] ? params['height'].to_i : 400
  
  # Generate graph
  png = GraphGenerator.generate(data, graph_type, width, height)
  
  content_type 'image/png'
  png.to_blob
end

# ─── Graph as SVG ───
get '/graph.svg' do
  content_type 'image/svg+xml'
  
  unless session[:user_id]
    status 401
    return { error: 'Not logged in' }.to_xml
  end
  
  user = DB.find_user_by_id(session[:user_id])
  
  if user.nil?
    session.clear
    status 401
    return { error: 'Session invalid' }.to_xml
  end
  
  # Build data
  data = {}
  data['X'] = user[:followers] if user[:followers] > 0
  
  devto_stats = DB.get_cached_stats(user[:id], 'devto')
  data['dev.to'] = devto_stats[:followers] if devto_stats && devto_stats[:followers] > 0
  
  youtube_stats = DB.get_cached_stats(user[:id], 'youtube')
  data['YouTube'] = youtube_stats[:followers] if youtube_stats && youtube_stats[:followers] > 0
  
  github_stats = DB.get_cached_stats(user[:id], 'github')
  data['GitHub'] = github_stats[:followers] if github_stats && github_stats[:followers] > 0
  
  return { error: 'No data' }.to_xml if data.empty?
  
  # Generate SVG
  max_value = data.values.max.to_f
  return { error: 'No data' }.to_xml if max_value == 0
  
  width = 800
  height = 400
  margin = { top: 40, right: 40, bottom: 60, left: 60 }
  chart_width = width - margin[:left] - margin[:right]
  chart_height = height - margin[:top] - margin[:bottom]
  
  colors = {
    'X' => '#1DA1F2',
    'dev.to' => '#000000',
    'YouTube' => '#FF0000',
    'GitHub' => '#24292F'
  }
  
  svg = <<~SVG
    <svg xmlns="http://www.w3.org/2000/svg" width="#{width}" height="#{height}" viewBox="0 0 #{width} #{height}">
      <rect width="100%" height="100%" fill="white"/>
      <style>
        text { font-family: -apple-system, BlinkMacSystemFont, sans-serif; fill: #333; }
        .grid { stroke: #eee; stroke-width: 0.5; }
        .label { font-size: 12px; }
        .value { font-size: 14px; font-weight: 600; }
        .footer { font-size: 11px; fill: #999; }
      </style>
  SVG
  
  # Grid lines
  (0..5).each do |i|
    y = margin[:top] + chart_height - (i / 5.0 * chart_height)
    svg << "<line class='grid' x1='#{margin[:left]}' y1='#{y}' x2='#{width - margin[:right]}' y2='#{y}'/>"
    label = (i / 5.0 * max_value).round
    svg << "<text x='#{margin[:left] - 10}' y='#{y + 4}' text-anchor='end' class='label'>#{label}</text>"
  end
  
  graph_type = params['type'] || 'bar'
  
  if graph_type == 'line'
    points = data.each_with_index.map do |(name, value), index|
      x = margin[:left] + (index * (chart_width / (data.length - 1).to_f))
      y = margin[:top] + chart_height - (value / max_value * chart_height)
      "#{x},#{y}"
    end
    svg << "<polyline points='#{points.join(' ')}' fill='none' stroke='#1DA1F2' stroke-width='3'/>"
    
    data.each_with_index do |(name, value), index|
      x = margin[:left] + (index * (chart_width / (data.length - 1).to_f))
      y = margin[:top] + chart_height - (value / max_value * chart_height)
      svg << "<circle cx='#{x}' cy='#{y}' r='6' fill='#1DA1F2'/>"
      svg << "<circle cx='#{x}' cy='#{y}' r='3' fill='white'/>"
      svg << "<text x='#{x}' y='#{y - 15}' text-anchor='middle' class='value'>#{value}</text>"
      svg << "<text x='#{x}' y='#{height - margin[:bottom] + 25}' text-anchor='middle' class='label'>#{name}</text>"
    end
  elsif graph_type == 'histogram'
    bar_width = chart_width / data.length
    data.each_with_index do |(name, value), index|
      x = margin[:left] + (index * bar_width)
      bar_height = (value / max_value * chart_height)
      y = margin[:top] + chart_height - bar_height
      color = colors[name] || '#666'
      svg << "<rect x='#{x}' y='#{y}' width='#{bar_width}' height='#{bar_height}' fill='#{color}'/>"
      svg << "<text x='#{x + bar_width/2}' y='#{y - 10}' text-anchor='middle' class='value'>#{value}</text>"
      svg << "<text x='#{x + bar_width/2}' y='#{height - margin[:bottom] + 25}' text-anchor='middle' class='label'>#{name}</text>"
    end
  else
    bar_width = chart_width / data.length * 0.7
    gap = chart_width / data.length * 0.3
    data.each_with_index do |(name, value), index|
      x = margin[:left] + (index * (bar_width + gap)) + gap / 2
      bar_height = (value / max_value * chart_height)
      y = margin[:top] + chart_height - bar_height
      color = colors[name] || '#666'
      svg << "<rect x='#{x}' y='#{y}' width='#{bar_width}' height='#{bar_height}' fill='#{color}'/>"
      
      if bar_height > 30
        svg << "<text x='#{x + bar_width/2}' y='#{y + 20}' text-anchor='middle' class='value' fill='white'>#{value}</text>"
      else
        svg << "<text x='#{x + bar_width/2}' y='#{y - 10}' text-anchor='middle' class='value'>#{value}</text>"
      end
      svg << "<text x='#{x + bar_width/2}' y='#{height - margin[:bottom] + 25}' text-anchor='middle' class='label'>#{name}</text>"
    end
  end
  
  footer = "Updated: #{Time.now.strftime('%B %d, %Y at %H:%M')} UTC"
  svg << "<text x='#{margin[:left]}' y='#{height - 5}' class='footer'>#{footer}</text>"
  
  svg << "</svg>"
  svg
end

# ─── Public Graph URL ───
get '/u/:username/graph' do
  user = DB.find_user_by_x_username(params[:username])
  
  if user.nil?
    status 404
    return { error: 'User not found' }.to_json
  end
  
  session[:user_id] = user[:id]
  redirect "/graph?#{request.query_string}"
end

# ─── Start the server ───
if __FILE__ == $0
  port = ENV['PORT'] || 4567
  puts "🚀 Starting Social Graph server on http://localhost:#{port}"
  puts "📊 Visit http://localhost:#{port} to get started"
  Sinatra::Application.run! port: port
end
