class UnauthorizedError < StandardError; end

class ApiClient
  # CONFIGURACIÓN DE URL DE LA API
  # Para producción, definir la variable de entorno API_BASE_URL en docker-compose.yml
  # Ejemplo Producción: https://surgiapi.com
  # URL base de la API de producción
  BASE_URL = ENV.fetch("API_BASE_URL", "https://appsurgicorperu.com").freeze

  # Método de clase para autenticar al usuario y obtener un token JWT.
  def self.authenticate(username, password)
    conn = Faraday.new(url: BASE_URL) do |faraday|
      # El middleware de respuesta JSON se ha eliminado para evitar errores de parseo automáticos.
      faraday.adapter Faraday.default_adapter
      
      # EN PRODUCCIÓN: No forzamos el Host a localhost.
      # Se deja dinámico o por defecto.
      
      # Se especifica que se espera una respuesta JSON.
      faraday.headers["Accept"] = "application/json"
    end

    response = conn.post("/api/token/", JSON.generate({ username: username, password: password }), { "Content-Type" => "application/json" })
    
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
  def fetch_details(page: 1, **extra_params)
    # canje=T018,- excluye siempre las facturas de canje de los cálculos
    params = { format: :json, page: page, page_size: 1000, canje: "T018" }.merge(extra_params)
    
    # Soporte para alias de parámetros comunes (Retrocompatibilidad o claridad)
    params[:fecha_emision__gte] ||= params.delete(:start_date) if params[:start_date]
    params[:fecha_emision__lte] ||= params.delete(:end_date) if params[:end_date]
    
    # Soporte para 'product_codes' -> 'fd__prod'
    params[:fd__prod] ||= params.delete(:product_codes) if params[:product_codes]
    
    # Limpieza específica para 'Todas' que no es un valor real de API
    if params[:vendedor] == "Todas"
      params.delete(:vendedor)
    end
    
    if params[:vendor] == "Todas"
      params.delete(:vendor)
    end

    url = "/Fact_Detalle/"
    
    Rails.logger.info("API Request: #{BASE_URL}#{url} Params: #{params}")
    response = @conn.get(url, params)
    
    if response.success?
      JSON.parse(response.body, symbolize_names: true)
    elsif response.status == 401
      raise UnauthorizedError, "Token expirado"
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
  def fetch_details_pages(max_pages: 50, **params)
    all_results = []
    total_count = 0
    page = 1

    loop do
      break if page > max_pages

      data = fetch_details(page: page, **params)

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

  # Obtener Tabla Maestra de Productos (todas las páginas)
  def fetch_products
    fetch_all_resources("/SI_Producto/")
  end

  # Obtener descripciones de múltiples productos en una sola llamada con codigo__in
  def fetch_products_by_codes(codes)
    return {} if codes.blank?
    # NO usar CGI.escape — las comas deben enviarse literales para que Django las interprete como lista
    codes_param = codes.map(&:to_s).map(&:strip).join(",")
    # Construir URL sin encoding de comas
    url = "/SI_Producto/?format=json&codigo__in=#{codes_param}&fields=codigo,descripcion&page_size=500"
    Rails.logger.info("=== FETCH PRODUCTS BATCH (#{codes.length} codes) — URL: #{BASE_URL}#{url} ===")
    response = @conn.get(url)
    if response.success?
      data = JSON.parse(response.body, symbolize_names: true)
      results = data[:results] || []
      if results.any?
        Rails.logger.info("=== SI_Producto BATCH OK: #{results.length} results — first: #{results.first.inspect} ===")
      else
        Rails.logger.warn("=== SI_Producto BATCH 0 RESULTS — body[0..400]: #{response.body[0..400]} ===")
      end
      results.each_with_object({}) { |p, h| h[p[:codigo].to_s.strip] = p[:descripcion].to_s.strip }
    else
      Rails.logger.error("Error al obtener productos en lote: #{response.status} — #{response.body[0..200]}")
      {}
    end
  rescue => e
    Rails.logger.error("Error en fetch_products_by_codes: #{e.message}")
    {}
  end

  # Obtener Tabla de Comisiones por Producto
  def fetch_product_commissions
    fetch_all_resources("/Repr_Comision_Prod/")
  end

  # Obtener Tabla de Comisiones de Supervisores
  def fetch_supervisor_commissions
    fetch_all_resources("/Repr_Comision_Sup/")
  end

  # Obtener Tabla de Llaves Supervisor-Representante
  def fetch_supervisor_keys
    fetch_all_resources("/Repr_ComisionKey/")
  end

  # Obtener un producto específico por su código (Búsqueda rápida optimizada)
  def fetch_product_by_code(code)
    url = "/SI_Producto/"
    # El usuario solicita específicamente fields=codigo,descripcion y codigo=VALOR
    params = { fields: "codigo,descripcion", codigo: code }
    
    full_url = "#{BASE_URL}#{url}?#{Faraday::Utils.build_query(params)}"
    Rails.logger.info("DETALLE API PRODUCTO - Solicitando URL: #{full_url}")
    
    response = @conn.get(url, params)
    
    if response.success?
      parsed = JSON.parse(response.body, symbolize_names: true)
      # SI_Producto usa :codigo como campo clave (no :prod)
      result = parsed[:results]&.find { |p| p[:codigo].to_s.strip == code.to_s.strip }
      if result
        result
      else
        Rails.logger.warn("DETALLE API PRODUCTO - No se encontró resultado en el JSON para: #{code}")
      end
      result
    elsif response.status == 401
      raise UnauthorizedError, "Token expirado"
    else
      Rails.logger.error("DETALLE API PRODUCTO - Error #{response.status}: #{response.body}")
      nil
    end
  rescue => e
    Rails.logger.error("DETALLE API PRODUCTO - Excepción: #{e.message}")
    nil
  end

  # Actualiza el estado de la comisión enviando un PATCH a la URL específica del recurso
  def update_commission_status(resource_url, paid_status, field: :comision_pagada)
    payload = { field.to_sym => paid_status }
    
    # Asegurar que la ruta termine en / antes de los query parameters
    uri = URI.parse(resource_url)
    path = uri.path
    path += "/" unless path.end_with?("/")
    
    uri.path = path
    normalized_url = uri.to_s
    
    Rails.logger.info("Enviando PATCH a: #{normalized_url} con payload: #{payload.to_json}")
    
    response = @conn.patch(normalized_url, payload.to_json, { "Content-Type" => "application/json" })
    
    if response.success?
      { success: true, data: JSON.parse(response.body, symbolize_names: true) }
    else
      # Logging detallado para el desarrollador
      Rails.logger.error("Fallo PATCH #{normalized_url}: #{response.status} - #{response.body}")
      
      # Capturar error detallado de la API
      error_msg = begin
        JSON.parse(response.body)["detail"] || response.body
      rescue
        response.body
      end
      
      # Reportar error con contexto
      status_text = "Status #{response.status}: #{error_msg}"
      
      { success: false, error: status_text, status: response.status, body: response.body }
    end
  rescue => e
    Rails.logger.error("Excepción en update_commission_status: #{e.message}")
    { success: false, error: e.message }
  end

  # Obtiene la lista de usuarios.
  def fetch_users
    fetch_all_resources("/users/")
  end

  # Obtiene una página del historial de auditoría de comisiones (60 registros por página, desc por id)
  def get_audit_history(page: 1, comprobantes_filter: nil, usuario_filter: nil, vendedores_filter: nil)
    url = "/FactComision_Audit/?format=json&page=#{page}"
    url += "&comprobantes__contains=#{CGI.escape(comprobantes_filter)}" if comprobantes_filter.present?
    url += "&usuario__contains=#{CGI.escape(usuario_filter)}" if usuario_filter.present?
    url += "&vendedores__contains=#{CGI.escape(vendedores_filter)}" if vendedores_filter.present?
    Rails.logger.info("=== GET AUDIT HISTORY: #{BASE_URL}#{url} ===")
    response = @conn.get(url)
    if response.success?
      begin
        data = JSON.parse(response.body, symbolize_names: true)
        Rails.logger.info("=== AUDIT HISTORY RESPONSE status=#{response.status} count=#{data[:count]} next=#{data[:next]} ===")
        {
          records: data[:results] || [],
          has_more: data[:next].present?
        }
      rescue => e
        Rails.logger.error("Error al parsear auditoría: #{e.message}")
        { records: [], has_more: false }
      end
    else
      Rails.logger.error("Error al obtener auditoría: HTTP #{response.status} - #{response.body}")
      { records: [], has_more: false }
    end
  end

  # Crea una entrada de auditoría (Historial)
  def create_audit_entry(usuario:, tipo_comision:, detalles:)
    # detalles: array de { invoice, amount, vendor }
    
    unique_invoices = detalles.map { |d| d[:invoice] }.uniq
    total_amount = detalles.sum { |d| d[:amount].to_f }.round(2)
    
    # Concatenar campos con comas según solicitud del usuario
    comprobantes_str = detalles.map { |d| d[:invoice].to_s.strip }.join(", ")
    comisiones_str   = detalles.map { |d| '%.2f' % d[:amount].to_f }.join(", ")
    vendedores_str   = detalles.map { |d| d[:vendor].to_s.strip }.join(", ")

    payload = {
      usuario: usuario,
      tipo_comision: tipo_comision,
      comprobantes: comprobantes_str,
      comisiones: comisiones_str,
      vendedores: vendedores_str,
      cant_fact: unique_invoices.size,
      total_comision: total_amount,
      fecha_hora: Time.current.iso8601
    }

    Rails.logger.info("Enviando Auditoría: #{payload.inspect}")

    response = @conn.post("/FactComision_Audit/?format=json", payload.to_json, { "Content-Type" => "application/json" })
    
    if response.success?
      { success: true, data: JSON.parse(response.body, symbolize_names: true) }
    else
      Rails.logger.error("Error API Auditoría: #{response.status} - #{response.body}")
      { success: false, error: response.body }
    end
  rescue => e
    Rails.logger.error("Excepción en create_audit_entry: #{e.message}")
    { success: false, error: e.message }
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
        elsif response.status == 401
          raise UnauthorizedError, "Token expirado"
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
