# graph.rb
require 'sinatra'
require 'sinatra/contrib'
require 'chunky_png'
require 'json'
require 'time'
require_relative 'db'

# ─── Configuration ───
configure do
  set :graph_colors, {
    x: ChunkyPNG::Color.rgb(29, 161, 242),      # X blue
    devto: ChunkyPNG::Color.rgb(0, 0, 0),       # Black
    youtube: ChunkyPNG::Color.rgb(255, 0, 0),   # Red
    github: ChunkyPNG::Color.rgb(36, 41, 47)    # GitHub dark
  }
  
  set :graph_defaults, {
    width: 800,
    height: 400,
    background: ChunkyPNG::Color::WHITE,
    text_color: ChunkyPNG::Color.rgb(51, 51, 51),
    grid_color: ChunkyPNG::Color.rgb(238, 238, 238),
    font_size: 12
  }
end

# ─── Graph Generator ───

module GraphGenerator
  def self.generate(data, type = 'bar', width = 800, height = 400)
    case type
    when 'bar'
      generate_bar_chart(data, width, height)
    when 'line'
      generate_line_chart(data, width, height)
    when 'histogram'
      generate_histogram(data, width, height)
    else
      generate_bar_chart(data, width, height)
    end
  end

  # ── Bar Chart ──
  def self.generate_bar_chart(data, width, height)
    png = ChunkyPNG::Image.new(width, height, ChunkyPNG::Color::WHITE)
    
    # Margins
    margin = { top: 40, right: 40, bottom: 60, left: 60 }
    chart_width = width - margin[:left] - margin[:right]
    chart_height = height - margin[:top] - margin[:bottom]
    
    # Find max value
    max_value = data.values.map { |v| v[:value] }.max.to_f
    return png if max_value == 0
    
    # Sort data (optional)
    sorted_data = data.sort_by { |k, v| -v[:value] }
    
    # Draw grid lines
    (0..5).each do |i|
      y = margin[:top] + chart_height - (i / 5.0 * chart_height)
      png.line(margin[:left], y, width - margin[:right], y, settings.graph_defaults[:grid_color])
      
      # Add value labels
      label = (i / 5.0 * max_value).round
      png.text(margin[:left] - 10, y - 6, label.to_s, settings.graph_defaults[:text_color])
    end
    
    # Draw bars
    bar_width = chart_width / sorted_data.length * 0.7
    gap = chart_width / sorted_data.length * 0.3
    
    sorted_data.each_with_index do |(platform, stats), index|
      x = margin[:left] + (index * (bar_width + gap)) + gap / 2
      bar_height = (stats[:value] / max_value * chart_height).round
      y = margin[:top] + chart_height - bar_height
      
      # Draw bar
      color = settings.graph_colors[platform.to_sym] || ChunkyPNG::Color.rgb(100, 100, 100)
      png.rect(x, y, x + bar_width, margin[:top] + chart_height, color, color)
      
      # Draw value on top of bar
      if bar_height > 30
        png.text(x + 5, y + 10, stats[:value].to_s, ChunkyPNG::Color::WHITE)
      else
        png.text(x + 5, y - 20, stats[:value].to_s, settings.graph_defaults[:text_color])
      end
      
      # Draw platform label
      label = platform.to_s.capitalize
      label_x = x + (bar_width / 2) - (label.length * 4)
      png.text(label_x, height - margin[:bottom] + 20, label, settings.graph_defaults[:text_color])
    end
    
    # Add footer
    footer = "Updated: #{Time.now.strftime('%B %d, %Y at %H:%M')} UTC"
    png.text(margin[:left], height - 5, footer, ChunkyPNG::Color.rgb(153, 153, 153))
    
    png
  end

  # ── Line Chart ──
  def self.generate_line_chart(data, width, height)
    png = ChunkyPNG::Image.new(width, height, ChunkyPNG::Color::WHITE)
    
    margin = { top: 40, right: 40, bottom: 60, left: 60 }
    chart_width = width - margin[:left] - margin[:right]
    chart_height = height - margin[:top] - margin[:bottom]
    
    max_value = data.values.map { |v| v[:value] }.max.to_f
    return png if max_value == 0
    
    sorted_data = data.sort_by { |k, v| -v[:value] }
    
    # Draw grid lines
    (0..5).each do |i|
      y = margin[:top] + chart_height - (i / 5.0 * chart_height)
      png.line(margin[:left], y, width - margin[:right], y, settings.graph_defaults[:grid_color])
      
      label = (i / 5.0 * max_value).round
      png.text(margin[:left] - 10, y - 6, label.to_s, settings.graph_defaults[:text_color])
    end
    
    # Draw line
    points = sorted_data.each_with_index.map do |(platform, stats), index|
      x = margin[:left] + (index * (chart_width / (sorted_data.length - 1).to_f))
      y = margin[:top] + chart_height - (stats[:value] / max_value * chart_height)
      [x, y]
    end
    
    # Draw lines between points
    points.each_cons(2) do |p1, p2|
      color = ChunkyPNG::Color.rgb(29, 161, 242)  # X blue as primary
      png.line(p1[0].round, p1[1].round, p2[0].round, p2[1].round, color, 3)
    end
    
    # Draw points and labels
    sorted_data.each_with_index do |(platform, stats), index|
      x, y = points[index]
      
      # Draw circle at point
      png.circle(x.round, y.round, 6, ChunkyPNG::Color.rgb(29, 161, 242), ChunkyPNG::Color.rgb(29, 161, 242))
      png.circle(x.round, y.round, 3, ChunkyPNG::Color::WHITE, ChunkyPNG::Color::WHITE)
      
      # Draw value
      png.text(x - 10, y - 25, stats[:value].to_s, settings.graph_defaults[:text_color])
      
      # Draw platform label
      label = platform.to_s.capitalize
      png.text(x - 10, height - margin[:bottom] + 20, label, settings.graph_defaults[:text_color])
    end
    
    # Add footer
    footer = "Updated: #{Time.now.strftime('%B %d, %Y at %H:%M')} UTC"
    png.text(margin[:left], height - 5, footer, ChunkyPNG::Color.rgb(153, 153, 153))
    
    png
  end

  # ── Histogram ──
  def self.generate_histogram(data, width, height)
    png = ChunkyPNG::Image.new(width, height, ChunkyPNG::Color::WHITE)
    
    margin = { top: 40, right: 40, bottom: 60, left: 60 }
    chart_width = width - margin[:left] - margin[:right]
    chart_height = height - margin[:top] - margin[:bottom]
    
    max_value = data.values.map { |v| v[:value] }.max.to_f
    return png if max_value == 0
    
    sorted_data = data.sort_by { |k, v| v[:value] }
    
    # Draw grid lines
    (0..5).each do |i|
      y = margin[:top] + chart_height - (i / 5.0 * chart_height)
      png.line(margin[:left], y, width - margin[:right], y, settings.graph_defaults[:grid_color])
      
      label = (i / 5.0 * max_value).round
      png.text(margin[:left] - 10, y - 6, label.to_s, settings.graph_defaults[:text_color])
    end
    
    # Draw histogram bars (touching)
    bar_width = chart_width / sorted_data.length
    
    sorted_data.each_with_index do |(platform, stats), index|
      x = margin[:left] + (index * bar_width)
      bar_height = (stats[:value] / max_value * chart_height).round
      y = margin[:top] + chart_height - bar_height
      
      # Draw bar
      color = settings.graph_colors[platform.to_sym] || ChunkyPNG::Color.rgb(100, 100, 100)
      png.rect(x, y, x + bar_width, margin[:top] + chart_height, color, color)
      
      # Draw value
      png.text(x + 5, y - 15, stats[:value].to_s, settings.graph_defaults[:text_color])
      
      # Draw platform label
      label = platform.to_s.capitalize
      label_x = x + (bar_width / 2) - (label.length * 4)
      png.text(label_x, height - margin[:bottom] + 20, label, settings.graph_defaults[:text_color])
    end
    
    # Add footer
    footer = "Updated: #{Time.now.strftime('%B %d, %Y at %H:%M')} UTC"
    png.text(margin[:left], height - 5, footer, ChunkyPNG::Color.rgb(153, 153, 153))
    
    png
  end
end

# ─── Routes ───

# ── Generate Graph ──
get '/graph' do
  content_type :json
  
  unless session[:user_id]
    status 401
    return { error: 'Not logged in' }.to_json
  end
  
  # Get user and stats
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
  
  # Return as image
  content_type 'image/png'
  png.to_blob
end

# ── Graph as SVG (cleaner, scalable) ──
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
  
  # Colors
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
  
  # Chart type (default: bar)
  graph_type = params['type'] || 'bar'
  
  if graph_type == 'line'
    # ── SVG Line Chart ──
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
    # ── SVG Histogram ──
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
    # ── SVG Bar Chart (default) ──
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
  
  # Footer
  footer = "Updated: #{Time.now.strftime('%B %d, %Y at %H:%M')} UTC"
  svg << "<text x='#{margin[:left]}' y='#{height - 5}' class='footer'>#{footer}</text>"
  
  svg << "</svg>"
  svg
end

# ── Embeddable Graph URL ──
get '/u/:username/graph' do
  # Find user by X username
  user = DB.find_user_by_x_username(params[:username])
  
  if user.nil?
    status 404
    return { error: 'User not found' }.to_json
  end
  
  # Store user_id in session for graph generation
  session[:user_id] = user[:id]
  
  # Redirect to graph route
  redirect "/graph?#{request.query_string}"
end

# ─── Helper to find by X username ───
module DB
  def self.find_user_by_x_username(username)
    result = DB.execute('SELECT * FROM users WHERE x_username = ?', username)
    result.first ? map_user(result.first) : nil
  end
end
