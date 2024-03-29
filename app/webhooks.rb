require 'json'
require 'uri'
require 'net/http'
require 'aws-sdk-s3'

def lambda_handler(event:, context:)
  message = JSON.parse(event['body'])['message']
  chat_id = message.dig('chat', 'id')
  movie_name = message['text']

  movie = fetch_movie_info(movie_name)

  if movie
    send_movie_info(chat_id, movie)
  else
    send_text_message(chat_id, "No film found with name #{movie_name}")
  end
ensure
  { statusCode: 200, body: { message: 'OK' } }
end

def fetch_movie_info(movie_name)
  url = URI("https://api.themoviedb.org/3/search/movie?query=#{movie_name}&page=1")
  request = Net::HTTP::Get.new(url)
  request["Accept"] = 'application/json'
  request["Authorization"] = "Bearer #{ENV['MOVIE_DB_TOKEN']}"

  response = Net::HTTP.start(url.host, url.port, use_ssl: url.scheme == 'https') do |http|
    http.request(request)
  end

  JSON.parse(response.body)['results'].first if response.is_a?(Net::HTTPSuccess)
rescue StandardError => e
  puts "Error fetching movie info: #{e.message}"
  nil
end

def send_text_message(chat_id, text)
  uri = URI("https://api.telegram.org/bot#{ENV['TG_TOKEN']}/sendMessage")
  message = { chat_id: chat_id, text: text }
  post_request(uri, message)
end

def send_movie_info(chat_id, movie)
  if poster_path = movie['poster_path']
    photo_url = "https://image.tmdb.org/t/p/w500#{poster_path}"
    caption = "Name: #{movie['title']}\nDescription: #{movie['overview']}"

    movie_id = movie['id']
    s3_photo_key = movie_name_by_id(movie_id)
    if image_cached?(s3_photo_key)
      s3_url = URI(s3_resource.bucket(bucket_name)
                          .object(s3_photo_key)
                          .presigned_url(:get))


      send_photo(chat_id, s3_url.to_s, "Send from s3\n" + caption)
    else
      send_photo(chat_id, photo_url, "Send from site\n" + caption)
      cache_photo(photo_url, movie_id)
    end
  else
    send_text_message(chat_id, "Movie found but no poster available.")
  end
rescue StandardError => e
  puts "Error sending movie info: #{e.message}"
end


def send_photo(chat_id, photo_url, caption)
  uri = URI("https://api.telegram.org/bot#{ENV['TG_TOKEN']}/sendPhoto")
  message = { chat_id: chat_id, photo: photo_url, caption: caption }
  post_request(uri, message)
end

def cache_photo(photo_url, movie_id)
  image_data = Net::HTTP.get(URI(photo_url))
  s3.put_object(bucket: bucket_name,
                key: movie_name_by_id(movie_id),
                body: image_data)
rescue StandardError => e
  puts "Error sending photo and caching: #{e.message}"
end

def post_request(uri, body)
  request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
  request.body = body.to_json

  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
    http.request(request)
  end

  puts response.body unless response.is_a?(Net::HTTPSuccess)
rescue StandardError => e
  puts "HTTP request failed: #{e.message}"
end

def s3
  @s3 ||= Aws::S3::Client.new
end

def s3_resource
  @s3_resource ||= Aws::S3::Resource.new
end

def image_cached?(key)
  s3.head_object(bucket: bucket_name, key: key)

  true
rescue
  false
end

def movie_name_by_id(movie_id)
  "movie-#{movie_id}.jpg"
end

def bucket_name
  ENV['IMAGES_BUCKET']
end
