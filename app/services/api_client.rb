class ApiClient
  # CONFIGURACIÓN DE URL DE LA API
  # Para producción, definir la variable de entorno API_BASE_URL en docker-compose.yml
  # Ejemplo Producción: https://surgiapi.com
  # URL base de la API de producción
  BASE_URL = ENV.fetch("API_BASE_URL", "https://appsurgicorperu.com").freeze

  # Método de clase para autenticar al usuario y obtener un token JWT.
  def self.authenticate(username, password)
    conn = Faraday.new(url: BASE_URL) do |faraday|
      faraday.request :json
      # El middleware de respuesta JSON se ha eliminado para evitar errores de parseo automáticos.
      faraday.adapter Faraday.default_adapter
      
      # EN PRODUCCIÓN: No forzamos el Host a localhost.
      # Se deja dinámico o por defecto.
      
      # Se especifica que se espera una respuesta JSON.
      faraday.headers["Accept"] = "application/json"
    end

    response = conn.post("/api/token/", { username: username, password: password })
    
    if response.success?
      body = JSON.parse(response.body, symbolize_names: true)
      body[:access] # Retorna el token de acceso
    else
      safe_body = response.body.to_s.dup.force_encoding("UTF-8").scrub("?")
      Rails.logger.error("Fallo de Autenticación: #{response.status} - #{safe_body}")
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
      faraday.adapter Faraday.default_adapter
    end
  end

  # Obtiene los detalles de facturas (una sola página).
  # Ahora la API retorna información anidada en 'fd' (Factura Detalle).
  def fetch_details(page: 1, start_date: nil, end_date: nil, vendor: nil, product_codes: nil)
    params = { format: :json, page: page, page_size: 1000 }
    params[:fecha_emision__gte] = start_date if start_date
    params[:fecha_emision__lte] = end_date if end_date
    params[:vendedor] = vendor if vendor.present? && vendor != "Todas"
    params[:fd__prod] = product_codes if product_codes.present?

    url = "/Fact_Detalle/"
    
    Rails.logger.info("API Request: #{BASE_URL}#{url} Params: #{params}")
    response = @conn.get(url, params)
    
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
  def fetch_details_pages(max_pages: 50, start_date: nil, end_date: nil, vendor: nil, product_codes: nil)
    all_results = []
    total_count = 0
    page = 1

    loop do
      break if page > max_pages

      data = fetch_details(page: page, start_date: start_date, end_date: end_date, vendor: vendor, product_codes: product_codes)

      if data.is_a?(Hash) && data[:results]
        total_count = data[:count] || 0
        current_count = data[:results].count
        all_results.concat(data[:results]) # Acumular resultados
        
        Rails.logger.info("Página #{page}: Obtenidos #{current_count} elementos. Total hasta ahora: #{all_results.count}")

        break if data[:next].nil? || data[:results].empty?
        
        page += 1
      else
        Rails.logger.warn("Bucle de obtención interrumpido: Formato de datos no válido o error en la página #{page}")
        break
      end
    end

    { count: total_count, results: all_results }
  end

  # Obtiene los DETALLES reales (Ítems de factura) desde /Facturas/
  # Según el usuario, 'Facturas' contiene el detalle (producto, precio) y 'Fact_Detalle' la cabecera.
  def fetch_invoice_items(page: 1, start_date: nil, end_date: nil)
    url = "/Facturas/?format=json&page=#{page}&page_size=1000"
    # Asumimos que también soporta filtrado por fecha, si no, habría que traer todo (lo cual es peligroso)
    # Si la API está bien diseñada, debería permitir filtrar detalles por fecha de emisión de la factura padre.
    url += "&fecha_emision__gte=#{start_date}" if start_date
    url += "&fecha_emision__lte=#{end_date}" if end_date

    Rails.logger.info("API Request Items: #{BASE_URL}#{url}")
    response = @conn.get(url)
    
    if response.success?
      JSON.parse(response.body, symbolize_names: true)
    elsif response.status == 401
      raise UnauthorizedError, "Token expirado"
    else
      safe_body = response.body.to_s.dup.force_encoding("UTF-8").scrub("?")
      Rails.logger.error("Error API (Items): #{response.status} - #{safe_body}")
      { count: 0, results: [] }
    end
  rescue Faraday::Error => e
    Rails.logger.error("Error de Conexión API (Items): #{e.message}")
    { count: 0, results: [] }
  rescue JSON::ParserError => e
    Rails.logger.error("Error de Parseo JSON (Items): #{e.message}")
    { count: 0, results: [] }
  end

  # Obtiene TODAS las páginas de ITEMS (Detalle)
  def fetch_invoice_items_pages(max_pages: 50, start_date: nil, end_date: nil)
    all_results = []
    page = 1

    loop do
      break if page > max_pages

      begin
        data = fetch_invoice_items(page: page, start_date: start_date, end_date: end_date)

        if data.is_a?(Hash) && data[:results]
          current_count = data[:results].count
          all_results.concat(data[:results])
          Rails.logger.info("Página de Ítems #{page}: Obtenidos #{current_count} elementos.")

          break if data[:next].nil? || data[:results].empty?
          page += 1
        else
          break
        end
      rescue UnauthorizedError
        raise
      end
    end

    all_results
  end

  # Obtener Tabla de Comisiones de Representantes
  def fetch_commissions
    fetch_all_resources("/Repr_Comision/")
  end

  # Obtener Tabla Maestro de Productos (para descripciones)
  def fetch_products
    fetch_all_resources("/SI_Producto/")
  end

  # Obtiene la lista de usuarios.
  def fetch_users
    fetch_all_resources("/users/")
  end

  private

  # Método genérico para traer todos los recursos paginados con reintentos básicos.
  def fetch_all_resources(endpoint, max_pages: 50)
    all_results = []
    page = 1
    
    Rails.logger.info("Obteniendo Recurso: #{endpoint}")
    
    loop do
      break if page > max_pages
      
      begin
        # Reducimos page_size a 200 para evitar tiempo de espera agotado o exceso de memoria.
        response = @conn.get("#{endpoint}?format=json&page=#{page}&page_size=200")
        
        if response.success?
          begin
            data = JSON.parse(response.body, symbolize_names: true)
            if data.is_a?(Hash) && data[:results]
              all_results.concat(data[:results])
              Rails.logger.info("#{endpoint} Página #{page}: Obtenidos #{data[:results].count} elementos.")
              break if data[:next].nil? || data[:results].empty?
              page += 1
            else
              Rails.logger.error("#{endpoint} Error: Formato inesperado en página #{page}")
              break
            end
          rescue JSON::ParserError => e
            Rails.logger.error("#{endpoint} Error de JSON: #{e.message}")
            break
          end
        else
          Rails.logger.error("#{endpoint} Error de API: #{response.status} - #{response.body}")
          break 
        end
      rescue Faraday::Error => e
        Rails.logger.error("#{endpoint} Error de Conexión: #{e.message}")
        break 
      end
    end
    
    Rails.logger.info("#{endpoint} Total obtenidos: #{all_results.count}")
    all_results
  end
end
