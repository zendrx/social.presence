# src/db.rb
require 'pg'
require 'time'
require 'bcrypt'

# ─── Database Connection ───
DB = PG.connect(
  host: ENV['DB_HOST'] || 'localhost',
  port: ENV['DB_PORT'] || 5432,
  dbname: ENV['DB_NAME'] || 'social_graph',
  user: ENV['DB_USER'] || 'postgres',
  password: ENV['DB_PASSWORD'] || ''
)

# ─── Create Tables ───

# Users table
DB.exec <<-SQL
  CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    x_id TEXT UNIQUE,
    x_username TEXT,
    name TEXT,
    avatar_url TEXT,
    followers INTEGER DEFAULT 0,
    following INTEGER DEFAULT 0,
    tweets INTEGER DEFAULT 0,
    listed INTEGER DEFAULT 0,
    verified BOOLEAN DEFAULT FALSE,
    joined_at TEXT,
    description TEXT,
    location TEXT,
    website_url TEXT,
    email TEXT UNIQUE,
    password_hash TEXT,
    confirmation_token TEXT,
    confirmed BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  )
SQL

# X tokens table
DB.exec <<-SQL
  CREATE TABLE IF NOT EXISTS x_tokens (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
    access_token TEXT NOT NULL,
    refresh_token TEXT NOT NULL,
    expires_at TIMESTAMP NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  )
SQL

# Social config table
DB.exec <<-SQL
  CREATE TABLE IF NOT EXISTS social_config (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
    devto_handle TEXT,
    youtube_channel TEXT,
    github_username TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(user_id)
  )
SQL

# Cached stats table
DB.exec <<-SQL
  CREATE TABLE IF NOT EXISTS cached_stats (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
    platform TEXT NOT NULL,
    followers INTEGER DEFAULT 0,
    fetched_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(user_id, platform)
  )
SQL

# Create indexes for performance
DB.exec <<-SQL
  CREATE INDEX IF NOT EXISTS idx_users_x_id ON users(x_id);
  CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
  CREATE INDEX IF NOT EXISTS idx_x_tokens_user_id ON x_tokens(user_id);
  CREATE INDEX IF NOT EXISTS idx_cached_stats_user_id ON cached_stats(user_id);
SQL

# ─── Module ───
module DB
  # ── User Methods ──

  def self.find_user_by_x_id(x_id)
    result = DB.exec_params('SELECT * FROM users WHERE x_id = $1', [x_id])
    result.ntuples > 0 ? map_user(result[0]) : nil
  end

  def self.find_user_by_id(id)
    result = DB.exec_params('SELECT * FROM users WHERE id = $1', [id])
    result.ntuples > 0 ? map_user(result[0]) : nil
  end

  def self.find_user_by_email(email)
    result = DB.exec_params('SELECT * FROM users WHERE email = $1', [email])
    result.ntuples > 0 ? map_user(result[0]) : nil
  end

  def self.find_user_by_x_username(username)
    result = DB.exec_params('SELECT * FROM users WHERE x_username = $1', [username])
    result.ntuples > 0 ? map_user(result[0]) : nil
  end

  def self.user_exists?(email)
    result = DB.exec_params('SELECT id FROM users WHERE email = $1', [email])
    result.ntuples > 0
  end

  def self.create_user_from_x(x_id, username, name, avatar_url, followers, following, tweets, listed, verified, joined_at, description, location, website_url)
    result = DB.exec_params(
      'INSERT INTO users (x_id, x_username, name, avatar_url, followers, following, tweets, listed, verified, joined_at, description, location, website_url)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
       RETURNING id',
      [x_id, username, name, avatar_url, followers, following, tweets, listed, verified, joined_at, description, location, website_url]
    )
    result[0]['id'].to_i
  end

  def self.update_user_stats(user_id, username, name, avatar_url, followers, following, tweets, listed, verified, joined_at, description, location, website_url)
    DB.exec_params(
      'UPDATE users SET
        x_username = $1, name = $2, avatar_url = $3, followers = $4,
        following = $5, tweets = $6, listed = $7, verified = $8,
        joined_at = $9, description = $10, location = $11, website_url = $12
       WHERE id = $13',
      [username, name, avatar_url, followers, following, tweets, listed, verified, joined_at, description, location, website_url, user_id]
    )
  end

  def self.update_x_stats(user_id, followers, following, tweets, listed)
    DB.exec_params(
      'UPDATE users SET followers = $1, following = $2, tweets = $3, listed = $4 WHERE id = $5',
      [followers, following, tweets, listed, user_id]
    )
  end

  # ── Email/Password User Methods ──

  def self.create_unconfirmed_user(email, password_hash, token)
    DB.exec_params(
      'INSERT INTO users (email, password_hash, confirmation_token, confirmed) VALUES ($1, $2, $3, FALSE)',
      [email, password_hash, token]
    )
  end

  def self.find_unconfirmed_user(email, token)
    result = DB.exec_params(
      'SELECT * FROM users WHERE email = $1 AND confirmation_token = $2 AND confirmed = FALSE',
      [email, token]
    )
    result.ntuples > 0 ? map_user(result[0]) : nil
  end

  def self.confirm_user(email)
    DB.exec_params('UPDATE users SET confirmed = TRUE WHERE email = $1', [email])
  end

  # ── Token Methods ──

  def self.save_x_tokens(user_id, access_token, refresh_token, expires_at)
    DB.exec_params(
      'INSERT INTO x_tokens (user_id, access_token, refresh_token, expires_at, updated_at)
       VALUES ($1, $2, $3, $4, CURRENT_TIMESTAMP)
       ON CONFLICT (user_id) DO UPDATE SET
         access_token = $2, refresh_token = $3, expires_at = $4, updated_at = CURRENT_TIMESTAMP',
      [user_id, access_token, refresh_token, expires_at.to_s]
    )
  end

  def self.get_x_tokens(user_id)
    result = DB.exec_params('SELECT * FROM x_tokens WHERE user_id = $1', [user_id])
    return nil if result.ntuples == 0

    row = result[0]
    {
      access_token: row['access_token'],
      refresh_token: row['refresh_token'],
      expires_at: Time.parse(row['expires_at'])
    }
  end

  # ── Social Config Methods ──

  def self.save_social_config(user_id, devto_handle, youtube_channel, github_username)
    DB.exec_params(
      'INSERT INTO social_config (user_id, devto_handle, youtube_channel, github_username, updated_at)
       VALUES ($1, $2, $3, $4, CURRENT_TIMESTAMP)
       ON CONFLICT (user_id) DO UPDATE SET
         devto_handle = $2, youtube_channel = $3, github_username = $4, updated_at = CURRENT_TIMESTAMP',
      [user_id, devto_handle, youtube_channel, github_username]
    )
  end

  def self.get_social_config(user_id)
    result = DB.exec_params('SELECT * FROM social_config WHERE user_id = $1', [user_id])
    return nil if result.ntuples == 0

    row = result[0]
    {
      devto_handle: row['devto_handle'],
      youtube_channel: row['youtube_channel'],
      github_username: row['github_username']
    }
  end

  # ── Cached Stats Methods ──

  def self.save_cached_stats(user_id, platform, followers)
    DB.exec_params(
      'INSERT INTO cached_stats (user_id, platform, followers, fetched_at)
       VALUES ($1, $2, $3, CURRENT_TIMESTAMP)
       ON CONFLICT (user_id, platform) DO UPDATE SET
         followers = $3, fetched_at = CURRENT_TIMESTAMP',
      [user_id, platform, followers]
    )
  end

  def self.get_cached_stats(user_id, platform)
    result = DB.exec_params(
      'SELECT * FROM cached_stats WHERE user_id = $1 AND platform = $2',
      [user_id, platform]
    )
    return nil if result.ntuples == 0

    row = result[0]
    {
      followers: row['followers'].to_i,
      fetched_at: Time.parse(row['fetched_at'])
    }
  end

  # ── Mapper ──

  def self.map_user(row)
    {
      id: row['id'].to_i,
      x_id: row['x_id'],
      x_username: row['x_username'],
      name: row['name'],
      avatar_url: row['avatar_url'],
      followers: row['followers'].to_i,
      following: row['following'].to_i,
      tweets: row['tweets'].to_i,
      listed: row['listed'].to_i,
      verified: row['verified'] == 't' || row['verified'] == true,
      joined_at: row['joined_at'],
      description: row['description'],
      location: row['location'],
      website_url: row['website_url'],
      email: row['email'],
      password_hash: row['password_hash'],
      confirmation_token: row['confirmation_token'],
      confirmed: row['confirmed'] == 't' || row['confirmed'] == true,
      created_at: row['created_at'] ? Time.parse(row['created_at']) : nil
    }
  end
end
