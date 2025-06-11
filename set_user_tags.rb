require 'dotenv/load'
require 'faraday'
require 'csv'

# Загрузка переменных окружения
API_URL = ENV['PACHCA_API_URL'] || 'https://api.pachca.com/api/shared/v1'
ADMIN_TOKEN = ENV['PACHCA_ADMIN_TOKEN']

unless ADMIN_TOKEN && !ADMIN_TOKEN.strip.empty?
  puts 'Ошибка: не найден токен администратора. Проверьте файл .env.'
  exit 1
end

def export_tags
  resp = Faraday.get("#{API_URL}/group_tags", {}, { 'Authorization' => "Bearer #{ADMIN_TOKEN}" })
  if resp.status == 200
    tags = JSON.parse(resp.body)['data']
    CSV.open('tags_export.csv', 'w', write_headers: true, headers: %w[id name]) do |csv|
      tags.each { |tag| csv << [tag['id'], tag['name']] }
    end
    puts 'Список тегов сохранён в tags_export.csv.'
  else
    puts 'Ошибка при получении списка тегов.'
  end
end

def export_users
  users = []
  page = 1
  loop do
    resp = Faraday.get("#{API_URL}/users", { page: page, per: 100 }, { 'Authorization' => "Bearer #{ADMIN_TOKEN}" })
    break unless resp.status == 200
    data = JSON.parse(resp.body)['data']
    break if data.empty?
    users.concat(data)
    page += 1
  end
  if users.empty?
    puts 'Не удалось получить список пользователей.'
    return
  end
  headers = %w[id email first_name last_name nickname department phone_number title tags]
  CSV.open('users_export.csv', 'w', write_headers: true, headers: headers) do |csv|
    users.each do |u|
      user_tags = ''
      if u['list_tags'].is_a?(Array)
        user_tags = u['list_tags'].compact.join(';')
      end
      row = headers.map { |h| h == 'tags' ? user_tags : u[h] }
      csv << row
    end
  end
  puts 'Список пользователей сохранён в users_export.csv.'
end

# Получить id всех существующих тегов (name => id)
def fetch_existing_tags
  tags = {}
  resp = Faraday.get("#{API_URL}/group_tags", {}, { 'Authorization' => "Bearer #{ADMIN_TOKEN}" })
  if resp.status == 200
    data = JSON.parse(resp.body)['data']
    data.each { |tag| tags[tag['name']] = tag['id'] }
  else
    puts 'Ошибка при получении списка тегов.'
  end
  tags
end

# Создать тег, если его нет
def create_tag(name)
  resp = Faraday.post("#{API_URL}/group_tags", { group_tag: { name: name } }, { 'Authorization' => "Bearer #{ADMIN_TOKEN}" })
  if resp.status == 200 || resp.status == 201
    id = JSON.parse(resp.body)['data']['id']
    puts "Тег '#{name}' создан."
    id
  elsif resp.status == 422 && resp.body.include?('taken')
    puts "Тег '#{name}' уже существует."
    nil
  else
    puts "Ошибка создания тега '#{name}': #{resp.body}"
    nil
  end
end


# Обновить теги пользователя
# Обновить теги пользователя
# Теперь используем поле list_tags (массив строк с названиями тегов), как требует API
# tag_names — массив названий тегов (строк)
def update_user_tags(user_id, tag_names)
  resp = Faraday.put(
    "#{API_URL}/users/#{user_id}",
    { user: { list_tags: tag_names } },
    { 'Authorization' => "Bearer #{ADMIN_TOKEN}" }
  )
  puts "API RESPONSE (user_id=#{user_id}): status=#{resp.status}, body=#{resp.body}"
  if resp.status == 200
    puts "Пользователю с id=#{user_id} успешно назначены теги."
  else
    puts "Ошибка назначения тегов пользователю id=#{user_id}: #{resp.body}"
  end
end

def find_user_id(email)
  page = 1
  loop do
    resp = Faraday.get("#{API_URL}/users", { page: page, per: 100 }, { 'Authorization' => "Bearer #{ADMIN_TOKEN}" })
    break unless resp.status == 200
    users = JSON.parse(resp.body)['data']
    user = users.find { |u| u['email'].to_s.strip.downcase == email.to_s.strip.downcase }
    return user['id'] if user
    break if users.empty?
    page += 1
  end
  nil
end

def assign_tags_from_csv
  begin
    users = CSV.read('users_tags.csv', headers: true)
  rescue
    puts 'Ошибка: не удалось прочитать файл users_tags.csv. Проверьте, что файл существует и корректен.'
    return
  end
  existing_tags = fetch_existing_tags
  users.each do |row|
    email = row['email']&.strip
    tags_raw = row['tags'] || ''
    tags = tags_raw.split(/[,;]/).map(&:strip).reject(&:empty?)
    # Пропускать строки-примеры и строки с workspace-тегами
    next if email.nil? || email.empty? || tags.empty? || email =~ /^(tags_from_workspace|example@example.com)$/i
    # Для каждого тега: если не существует — создать, но не создавать дубликаты
    tags.each do |tag|
      unless existing_tags[tag]
        tag_id = create_tag(tag)
        existing_tags[tag] = tag_id if tag_id
      end
    end
    user_id = find_user_id(email)
    if user_id
      # Получить текущие теги пользователя
      current_tags_resp = Faraday.get("#{API_URL}/users/#{user_id}", {}, { 'Authorization' => "Bearer #{ADMIN_TOKEN}" })
      current_tag_names = []
      if current_tags_resp.status == 200
        user_data = JSON.parse(current_tags_resp.body)
        # Получить текущие теги из list_tags
        if user_data['data'] && user_data['data']['list_tags'].is_a?(Array)
          current_tag_names = user_data['data']['list_tags'].map(&:to_s)
        end
      end
      # Объединить текущие и новые теги, убрать дубли
      all_tag_names = (current_tag_names + tags).uniq
      resp = Faraday.put(
        "#{API_URL}/users/#{user_id}",
        { user: { list_tags: all_tag_names } },
        { 'Authorization' => "Bearer #{ADMIN_TOKEN}" }
      )
      if resp.status == 200
        puts "[OK] #{email}: назначены теги: #{all_tag_names.join(', ')}"
      else
        puts "[Ошибка] #{email}: не удалось назначить теги (#{all_tag_names.join(', ')}). Ответ API: #{resp.body}"
      end
    else
      puts "[Ошибка] Пользователь с email #{email} не найден."
    end
  end
  puts 'Массовое назначение тегов завершено.'
end

# --- Меню ---
def create_users_tags_template
  # Получаем пользователей
  users = []
  page = 1
  loop do
    resp = Faraday.get("#{API_URL}/users", { page: page, per: 100 }, { 'Authorization' => "Bearer #{ADMIN_TOKEN}" })
    break unless resp.status == 200
    data = JSON.parse(resp.body)['data']
    break if data.empty?
    users.concat(data)
    page += 1
  end
  # Получаем все теги
  tags_resp = Faraday.get("#{API_URL}/group_tags", {}, { 'Authorization' => "Bearer #{ADMIN_TOKEN}" })
  tag_names = []
  tag_id_to_name = {}
  if tags_resp.status == 200
    tag_names = JSON.parse(tags_resp.body)['data'].map { |t| t['name'] }
    tag_id_to_name = JSON.parse(tags_resp.body)['data'].map { |t| [t['id'], t['name']] }.to_h
  end
  # Создаём шаблон users_tags.csv с уже назначенными тегами
  headers = %w[email first_name last_name tags comment]
  CSV.open('users_tags.csv', 'w', write_headers: true, headers: headers) do |csv|
    # Строка с примерами всех тегов, только если есть теги
    if tag_names.any?
      csv << ['tags_from_workspace', '', '', tag_names.join(';'), '']
    end
    # Пример строки
    csv << ['example@example.com', 'Иван', 'Иванов', 'backend;qa;lead', 'Пример для заполнения']
    users.each do |u|
      user_tags = ''
      if u['list_tags'].is_a?(Array) && !u['list_tags'].empty?
        user_tags = u['list_tags'].compact.join(';')
      elsif u['group_tags'].is_a?(Array) && !u['group_tags'].empty?
        user_tags = u['group_tags'].map { |tg| tg['name'] || tag_id_to_name[tg['id']] }.compact.join(';')
      end
      csv << [u['email'], u['first_name'], u['last_name'], user_tags, '']
    end
  end
  puts "\n=============================="
  puts "Шаблон users_tags.csv создан. Введите в таблице users_tags.csv теги для сотрудников в последней колонке."
  puts "Список существующих тегов:"
  puts tag_names.join(', ')
  puts "==============================\n"
end

loop do
  puts "\nЧто вы хотите сделать?"
  puts "1. Массово назначить или обновить теги пользователям."
  puts "2. Сделать отдельную выгрузку тегов из Пачки в tags_export.csv."
  puts "3. Сделать отдельную выгрузку всех пользователей из Пачки в users_export.csv."
  puts "4. Сделать users_tags.csv на основе пользователей, добавленных в Пачку."
  puts "5. Выйти"
  print "> "
  choice = STDIN.gets.strip
  case choice
  when '1'
    assign_tags_from_csv
  when '2'
    export_tags
  when '3'
    export_users
  when '4'
    create_users_tags_template
  when '5'
    puts 'Выход.'
    break
  else
    puts 'Некорректный выбор. Введите 1, 2, 3, 4 или 5.'
  end
end
