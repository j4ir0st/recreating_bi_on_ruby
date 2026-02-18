class ApiClient
  # CONFIGURACIÓN DE URL DE LA API
  # Para producción, definir la variable de entorno API_BASE_URL en docker-compose.yml
  # Ejemplo Producción: https://surgiapi.com
  # Ejemplo Desarrollo (Docker): http://host.docker.internal:8002
  BASE_URL = ENV.fetch("API_BASE_URL", "http://host.docker.internal:8002").freeze

  # Método de clase para autenticar al usuario y obtener un token JWT.
  # Recibe usuario y contraseña, y hace una petición POST a la API de Django.
  def self.authenticate(username, password)
    conn = Faraday.new(url: BASE_URL) do |faraday|
      faraday.request :json
      # El middleware de respuesta JSON se ha eliminado para evitar errores de parseo automáticos.
      # Se hace el parseo manual más abajo para mayor robustez.
      faraday.adapter Faraday.default_adapter
      
      # IMPORTANTE: Esta línea fuerza el Host a localhost:8002 para que Django acepte la conexión en entorno LOCAL.
      # EN PRODUCCIÓN: Si usas un dominio real (ej: surgiapi.com), COMENTA o ELIMINA esta línea,
      # o asegúrate de que coincida con tu dominio.
      if Rails.env.development? || BASE_URL.include?("host.docker.internal")
        faraday.headers["Host"] = "localhost:8002"
      end
      
      # Se especifica que se espera una respuesta JSON.
      faraday.headers["Accept"] = "application/json"
    end

    response = conn.post("/api/token/", { username: username, password: password })
    
    if response.success?
      # Parseamos manualmente la respuesta para evitar el error "no implicit conversion of Symbol into Integer"
      body = JSON.parse(response.body, symbolize_names: true)
      body[:access] # Retorna el token de acceso
    else
      Rails.logger.error("Fallo de Autenticación: #{response.status} - #{response.body}")
      nil
    end
  rescue JSON::ParserError => e
    Rails.logger.error("Error al parsear JSON de Auth: #{e.message} - Cuerpo: #{response&.body}")
    nil
  rescue Faraday::Error => e
    Rails.logger.error("Error de Conexión en Auth: #{e.message}")
    nil
  end

  # Inicializador: Configura la conexión Faraday con el token recibido.
  def initialize(token = nil)
    @conn = Faraday.new(url: BASE_URL) do |faraday|
      # Si hay token, usar autenticación Bearer (JWT).
      if token
        faraday.request :authorization, :Bearer, token
      end
      
      faraday.headers["Accept"] = "application/json"
      
      # IMPORTANTE: Configuración condicional del Host header para desarrollo local vs producción.
      if Rails.env.development? || BASE_URL.include?("host.docker.internal")
        faraday.headers["Host"] = "localhost:8002"
      end
      
      faraday.adapter Faraday.default_adapter
    end
  end

  # Obtiene los detalles de facturas (una sola página).
  # Soporta filtrado por fecha si se pasan start_date y end_date.
  # Se usa page_size=1000 para traer más datos por petición y reducir el número de llamadas.
  def fetch_details(page: 1, start_date: nil, end_date: nil)
    url = "/Fact_Detalle/?format=json&page=#{page}&page_size=1000"
    url += "&fecha_emision__gte=#{start_date}" if start_date # Fecha inicio (Mayor o igual)
    url += "&fecha_emision__lte=#{end_date}" if end_date     # Fecha fin (Menor o igual)

    response = @conn.get(url)
    if response.success?
      JSON.parse(response.body, symbolize_names: true)
    else
      Rails.logger.error("Error API (Detalles): #{response.status} - #{response.body}")
      { count: 0, results: [] }
    end
  rescue Faraday::Error => e
    Rails.logger.error("Error de Conexión API (Detalles): #{e.message}")
    { count: 0, results: [] }
  rescue JSON::ParserError => e
    Rails.logger.error("Error de Parseo JSON (Detalles): #{e.message}")
    { count: 0, results: [] }
  end

  # Obtiene TODAS las páginas disponibles para un rango de fechas.
  # Itera página por página hasta que no hay más resultados o se alcanza el límite (max_pages).
  def fetch_details_pages(max_pages: 50, start_date: nil, end_date: nil)
    all_results = []
    total_count = 0
    page = 1

    loop do
      # Romper el bucle si excedemos el límite de seguridad de páginas
      break if page > max_pages

      # Llamada a la API para la página actual
      data = fetch_details(page: page, start_date: start_date, end_date: end_date)

      if data.is_a?(Hash) && data[:results]
        total_count = data[:count] || 0
        all_results.concat(data[:results]) # Acumular resultados
        
        # Si no hay enlace a "siguiente" página ([:next]) o no hay resultados, terminamos.
        break if data[:next].nil? || data[:results].empty?
        
        page += 1
      else
        break
      end
    end

    { count: total_count, results: all_results }
  end
end
