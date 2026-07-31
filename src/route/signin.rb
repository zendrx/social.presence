# signing.rb
require 'sinatra'
require 'sinatra/contrib'      # For JSON, sessions
require 'bcrypt'
require 'json'
require 'securerandom'
require_relative 'db'

# ─── Session Configuration ───
configure do
  enable :sessions
  set :session_secret, ENV.fetch('SESSION_SECRET') { SecureRandom.hex(64) }
end

# ─── Helpers ───
def valid_email?(email)
  email =~ /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/
end

def generate_password
  SecureRandom.alphanumeric(12)
end

def hash_password(password)
  BCrypt::Password.create(password)
end

def verify_password(password, hashed)
  BCrypt::Password.new(hashed) == password
end

# ─── Routes ───

# ── Signup ──
post '/signup' do
  content_type :json
  
  request.body.rewind
  data = JSON.parse(request.body.read) rescue {}
  email = data['email'].to_s.strip
  
  # Validate email
  unless valid_email?(email)
    status 400
    return { error: 'Invalid email format' }.to_json
  end
  
  # Check if email already exists
  if DB.user_exists?(email)
    status 409
    return { error: 'Email already registered' }.to_json
  end
  
  # Generate password and hash it
  password = generate_password
  password_hash = hash_password(password)
  
  # Generate confirmation token
  confirmation_token = SecureRandom.hex(32)
  
  # Store unconfirmed user
  DB.create_unconfirmed_user(email, password_hash, confirmation_token)
  
  # Return the password (frontend shows it once)
  {
    status: 'ok',
    message: 'Account created. Please save your password and confirm.',
    password: password  # ⚠️ Only sent once, never stored
  }.to_json
end

# ── Confirm Email ──
post '/confirm' do
  content_type :json
  
  request.body.rewind
  data = JSON.parse(request.body.read) rescue {}
  email = data['email'].to_s.strip
  token = data['token'].to_s.strip
  
  # Find unconfirmed user by email and token
  user = DB.find_unconfirmed_user(email, token)
  
  if user.nil?
    status 404
    return { error: 'Invalid confirmation link or already confirmed' }.to_json
  end
  
  # Mark as confirmed
  DB.confirm_user(email)
  
  {
    status: 'ok',
    message: 'Email confirmed successfully. You can now log in.'
  }.to_json
end

# ── Login ──
post '/login' do
  content_type :json
  
  request.body.rewind
  data = JSON.parse(request.body.read) rescue {}
  email = data['email'].to_s.strip
  password = data['password'].to_s
  
  # Find user
  user = DB.find_user_by_email(email)
  
  # Check if user exists, is confirmed, and password matches
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
  
  # Start session
  session[:user_id] = user[:id]
  session[:email] = user[:email]
  
  {
    status: 'ok',
    message: 'Logged in successfully'
  }.to_json
end

# ── Logout ──
post '/logout' do
  session.clear
  { status: 'ok', message: 'Logged out' }.to_json
end

# ── Check Session (for frontend to verify auth) ──
get '/session' do
  content_type :json
  
  if session[:user_id]
    user = DB.find_user_by_id(session[:user_id])
    if user
      {
        status: 'ok',
        user: {
          id: user[:id],
          email: user[:email],
          confirmed: user[:confirmed]
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
