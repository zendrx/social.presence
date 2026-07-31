# signin.rb
require 'sinatra'
require 'sinatra/contrib'
require 'json'
require 'securerandom'
require 'net/http'
require 'uri'
require 'openssl'
require 'base64'
require 'time'
require_relative 'db'

# ─── Configuration ───
configure do
  enable :sessions
  set :session_secret, ENV.fetch('SESSION_SECRET') { SecureRandom.hex(64) }
  
  # X OAuth2 credentials
  set :x_client_id, ENV['X_CLIENT_ID']
  set :x_client_secret, ENV['X_CLIENT_SECRET']
  set :x_redirect_uri, ENV['X_REDIRECT_URI'] || 'http://localhost:4567/auth/x/callback'
end

# ─── Helpers ───
def generate_state
  SecureRandom.hex(16)
end

def generate_code_verifier
  SecureRandom.alphanumeric(128)
end

def generate_code_challenge(verifier)
  digest = OpenSSL::Digest::SHA256.digest(verifier)
  Base64.urlsafe_encode64(digest, padding: false)
end

# ── X API Calls ──

def get_x_user(access_token)
  uri = URI('https://api.x.com/2/users/me?user.fields=public_metrics,profile_image_url,verified,created_at,description,location,url')
  request = Net::HTTP::Get.new(uri)
  request['Authorization'] = "Bearer #{access_token}"
  
  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
    http.request(request)
  end
  
  if response.code == '200'
    data = JSON.parse(response.body)
    data['data']
  else
    nil
  end
end

def exchange_code_for_token(code, code_verifier)
  uri = URI('https://api.x.com/2/oauth2/token')
  request = Net::HTTP::Post.new(uri)
  request.set_form_data({
    code: code,
    grant_type: 'authorization_code',
    client_id: settings.x_client_id,
    redirect_uri: settings.x_redirect_uri,
    code_verifier: code_verifier
  })
  
  # Add basic auth header (client_id:client_secret)
  credentials = Base64.strict_encode64("#{settings.x_client_id}:#{settings.x_client_secret}")
  request['Authorization'] = "Basic #{credentials}"
  
  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
    http.request(request)
  end
  
  if response.code == '200'
    JSON.parse(response.body)
  else
    nil
  end
end

def refresh_access_token(refresh_token)
  uri = URI('https://api.x.com/2/oauth2/token')
  request = Net::HTTP::Post.new(uri)
  request.set_form_data({
    refresh_token: refresh_token,
    grant_type: 'refresh_token',
    client_id: settings.x_client_id
  })
  
  credentials = Base64.strict_encode64("#{settings.x_client_id}:#{settings.x_client_secret}")
  request['Authorization'] = "Basic #{credentials}"
  
  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
    http.request(request)
  end
  
  if response.code == '200'
    JSON.parse(response.body)
  else
    nil
  end
end

def get_valid_access_token(user_id)
  tokens = DB.get_x_tokens(user_id)
  return nil if tokens.nil?
  
  # Check if token is still valid (with 5-minute buffer)
  if tokens[:expires_at] && Time.now < (tokens[:expires_at] - 300)
    return tokens[:access_token]
  end
  
  # Token expired or about to expire, refresh it
  new_tokens = refresh_access_token(tokens[:refresh_token])
  if new_tokens
    expires_at = Time.now + new_tokens['expires_in'].to_i
    DB.save_x_tokens(
      user_id,
      new_tokens['access_token'],
      new_tokens['refresh_token'],
      expires_at
    )
    return new_tokens['access_token']
  end
  
  nil
end

def fetch_x_user_stats(access_token, username)
  uri = URI("https://api.x.com/2/users/by/username/#{username}?user.fields=public_metrics")
  request = Net::HTTP::Get.new(uri)
  request['Authorization'] = "Bearer #{access_token}"
  
  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
    http.request(request)
  end
  
  if response.code == '200'
    data = JSON.parse(response.body)
    metrics = data.dig('data', 'public_metrics')
    {
      followers: metrics['followers_count'],
      following: metrics['following_count'],
      tweets: metrics['tweet_count'],
      listed: metrics['listed_count']
    }
  else
    nil
  end
end

# ─── Routes ───

# ── Start X Login ──
get '/auth/x' do
  state = generate_state
  code_verifier = generate_code_verifier
  code_challenge = generate_code_challenge(code_verifier)
  
  # Store in session for callback
  session[:x_state] = state
  session[:x_code_verifier] = code_verifier
  
  # Build X authorization URL
  params = {
    response_type: 'code',
    client_id: settings.x_client_id,
    redirect_uri: settings.x_redirect_uri,
    state: state,
    code_challenge: code_challenge,
    code_challenge_method: 'S256',
    scope: 'users.read tweet.read offline.access'
  }
  
  auth_url = "https://x.com/i/oauth2/authorize?" + URI.encode_www_form(params)
  redirect auth_url
end

# ── X OAuth Callback ──
get '/auth/x/callback' do
  code = params['code']
  state = params['state']
  error = params['error']
  
  if error
    status 400
    return { error: "X login failed: #{error}" }.to_json
  end
  
  # Verify state
  if state != session[:x_state]
    status 400
    return { error: 'Invalid state parameter' }.to_json
  end
  
  # Exchange code for token
  tokens = exchange_code_for_token(code, session[:x_code_verifier])
  
  if tokens.nil?
    status 500
    return { error: 'Failed to exchange code for token' }.to_json
  end
  
  # Get user info from X
  x_user = get_x_user(tokens['access_token'])
  
  if x_user.nil?
    status 500
    return { error: 'Failed to get user info from X' }.to_json
  end
  
  # Extract metrics
  metrics = x_user['public_metrics'] || {}
  followers = metrics['followers_count'] || 0
  following = metrics['following_count'] || 0
  tweets = metrics['tweet_count'] || 0
  listed = metrics['listed_count'] || 0
  
  # Check if user exists in our DB
  user = DB.find_user_by_x_id(x_user['id'])
  
  if user.nil?
    # New user – create account
    user_id = DB.create_user_from_x(
      x_user['id'],
      x_user['username'],
      x_user['name'],
      x_user['profile_image_url'],
      followers,
      following,
      tweets,
      listed,
      x_user['verified'] || false,
      x_user['created_at'],
      x_user['description'],
      x_user['location'],
      x_user['url']
    )
  else
    user_id = user[:id]
    # Update user data
    DB.update_user_stats(
      user_id,
      x_user['username'],
      x_user['name'],
      x_user['profile_image_url'],
      followers,
      following,
      tweets,
      listed,
      x_user['verified'] || false,
      x_user['created_at'],
      x_user['description'],
      x_user['location'],
      x_user['url']
    )
  end
  
  # Save X tokens
  expires_at = Time.now + tokens['expires_in'].to_i
  DB.save_x_tokens(
    user_id,
    tokens['access_token'],
    tokens['refresh_token'],
    expires_at
  )
  
  # Start session
  session[:user_id] = user_id
  session[:x_username] = x_user['username']
  
  # Redirect to dashboard
  redirect '/dashboard'
end

# ── Fetch latest X stats (for dashboard) ──
get '/api/x/stats' do
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
  
  # Get valid access token
  access_token = get_valid_access_token(user[:id])
  
  if access_token.nil?
    status 500
    return { error: 'Failed to get X access token' }.to_json
  end
  
  # Fetch fresh stats
  stats = fetch_x_user_stats(access_token, user[:x_username])
  
  if stats.nil?
    status 500
    return { error: 'Failed to fetch X stats' }.to_json
  end
  
  # Update DB
  DB.update_x_stats(user[:id], stats[:followers], stats[:following], stats[:tweets], stats[:listed])
  DB.save_cached_stats(user[:id], 'x', stats[:followers])
  
  {
    status: 'ok',
    data: {
      username: user[:x_username],
      followers: stats[:followers],
      following: stats[:following],
      tweets: stats[:tweets],
      listed: stats[:listed]
    },
    fetched_at: Time.now.iso8601
  }.to_json
end

# ── Check Session ──
get '/session' do
  content_type :json
  
  if session[:user_id]
    user = DB.find_user_by_id(session[:user_id])
    if user
      {
        status: 'ok',
        user: {
          id: user[:id],
          x_username: user[:x_username],
          name: user[:name],
          avatar: user[:avatar_url],
          followers: user[:followers],
          following: user[:following],
          tweets: user[:tweets],
          listed: user[:listed],
          verified: user[:verified],
          joined: user[:joined_at]
        }
      }.to_json
    else
      session.clear
      status 401
      { error: 'Session invalid' }.to_json
    end
  else
    status 401
    { error: 'Not logged in' }.to_json
  end
end

# ── Logout ──
post '/logout' do
  session.clear
  { status: 'ok', message: 'Logged out' }.to_json
end

# ── Dashboard ──
get '/dashboard' do
  unless session[:user_id]
    redirect '/'
  end
  
  user = DB.find_user_by_id(session[:user_id])
  @user = user
  erb :dashboard
end
