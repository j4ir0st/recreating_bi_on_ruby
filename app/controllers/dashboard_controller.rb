class DashboardController < ApplicationController
  rescue_from Exception, with: :handle_unexpected_error

  def index
    @active_tab = params[:tab] || "vendedor"
    load_data
  end

  def productos
    @active_tab = "productos"
    load_data
    render partial: "dashboard/tabs/productos", locals: { dashboard: @dashboard, details: @product_details }
  end

  def vendedor
    @active_tab = "vendedor"
    load_data
    render partial: "dashboard/tabs/vendedor", locals: { dashboard: @dashboard, vendor_data: @vendor_data }
  end

  def reporte
    @active_tab = "reporte"
    load_data
    render partial: "dashboard/tabs/reporte", locals: { dashboard: @dashboard, monthly_data: @monthly_data }
  end

  private

  def handle_unexpected_error(exception)
    Rails.logger.error("DASHBOARD ERROR: #{exception.message}\n#{exception.backtrace.first(10).join("\n")}")
    
    error_msg = "Error inesperado: #{exception.message}"
    
    if request.xhr?
      render inline: "<div class='error-toast-ajax'>#{error_msg}</div>", status: :internal_server_error
    else
      # Prevenir bucle: si ya estamos en una ruta que falló, no redirigir a la misma
      if request.path == root_path
        render plain: "Error Crítico del Sistema: #{exception.message}. Por favor contacte al administrador.", status: :internal_server_error
      else
        redirect_to root_path, flash: { error_detail: error_msg }
      end
    end
  end

  def load_data
    begin
      client = ApiClient.new(session[:api_token])

    @selected_year = params[:year] || Date.today.year.to_s
    @selected_cancelado = params[:cancelado] || "Todo"
    
    current_month_str = Date.today.strftime("%Y-%m")
    
    if params[:date_range].blank?
      if @selected_year == Date.today.year.to_s
        @selected_month = current_month_str
      else
        @selected_month = "Todas" 
      end
    else
      @selected_month = params[:date_range]
    end
    
    start_date = nil
    end_date = nil

    if @selected_month.present? && @selected_month != "Todas"
      # Si el mes es 2026-02, queremos desde 2026-01-24 hasta 2026-02-23
      base_date = Date.strptime(@selected_month, "%Y-%m")
      end_date = Date.new(base_date.year, base_date.month, 23)
      start_date = (end_date - 1.month) + 1.day # Esto nos da el 24 del mes anterior
    else
      start_date = Date.new(@selected_year.to_i, 1, 1)
      end_date = Date.new(@selected_year.to_i, 12, 31)
    end

    start_date_str = start_date.strftime("%Y-%m-%d")
    end_date_str = end_date.strftime("%Y-%m-%d 23:59:59")

    # 1. Obtener Datos Maestros (Caché)
    @products = Rails.cache.fetch("si_productos", expires_in: 4.hours) do
      client.fetch_products
    end
    @commissions = Rails.cache.fetch("repr_comisiones", expires_in: 12.hours) do
      client.fetch_commissions
    end
    @product_commissions = Rails.cache.fetch("repr_comisiones_prod", expires_in: 12.hours) do
      client.fetch_product_commissions
    end

    # Crear mapas de búsqueda rápida
    @products_map = @products.index_by { |p| p[:codigo].to_s }
    @commissions_map = @commissions.index_by { |c| c[:nombre].to_s.strip.upcase }
    @product_commissions_map = @product_commissions.index_by { |pc| pc[:prod].to_s.strip }
    
    # 2. Obtener Facturas (Traemos todo el rango de fecha para filtrar en memoria con robustez)
    api_data = client.fetch_details_pages(
      max_pages: 50, 
      start_date: start_date_str, 
      end_date: end_date_str
    )
    raw_details = api_data[:results] || []

    # Normalizar llaves de cabeceras
    @details = raw_details.map { |d| d.transform_keys(&:to_s) }
    
    # Intentar resolver nombres de vendedores truncados usando la tabla de comisiones
    if @commissions.present?
      @details.each do |d|
        v_raw = d["vendedor"].to_s.strip
        # Si el nombre parece truncado (tiene puntos suspensivos o es muy corto)
        if v_raw.include?('...') || v_raw.length >= 15
          v_clean = v_raw.gsub('...', '').strip.upcase
          # Buscar un nombre en comisiones que comience con el nombre truncado
          full_name_info = @commissions.find do |c| 
            # Normalizar para comparación
            c_name = c[:nombre].to_s.strip.upcase
            # Comparación por prefijo
            c_name.start_with?(v_clean) || v_clean.start_with?(c_name)
          end
          
          if full_name_info
            d["vendedor"] = full_name_info[:nombre].to_s.strip
          end
        end
      end
    end
    
    # IMPORTANTE: Filtro manual de fechas en memoria (Respaldo)
    if @selected_month.present? && @selected_month != "Todas"
      @details = @details.select do |d|
        begin
          f_emision = Date.parse(d["fecha_emision"].to_s)
          f_emision >= start_date && f_emision <= end_date
        rescue
          true
        end
      end
    end

    # Filtro manual de Cancelado
    if @selected_cancelado != "Todo"
      @details = @details.select { |d| d["cancelado"] == @selected_cancelado }
    end
    
    # Mapa de Facturas por Número para el cruce
    @invoices_map = @details.index_by { |d| d["nro_fact"] } 

    # Aplicar Filtro de Vendedor (pero mantenemos PAGADAS y PENDIENTES para los KPIs)
    if params[:vendor].present? && params[:vendor] != "Todas"
      search_vendedor = params[:vendor].to_s.strip.upcase
      @details = @details.select { |d| d["vendedor"].to_s.strip.upcase == search_vendedor }
    end

    # 3. Procesar Datos para Vistas
    # Calcular KPIs (Basados en Cabeceras)
    @dashboard = calculate_kpis(@details, api_data[:count] || 0)
    
    # Agrupar por vendedor (Basado en Cabeceras)
    @vendor_data = group_by_vendor(@details)
    
    # Gráfico (Basado en Cabeceras)
    granularity = (@selected_month != "Todas") ? :day : :month
    @monthly_data = group_data(@details, granularity)
    
    # 4. Aplanar Datos usando el campo 'fd' (Factura Detalle) anidado
    @vendor_details = flatten_nested_data(@details, :vendor)
    @product_details = flatten_nested_data(@details, :product)

    # Listas para filtros
    if @commissions.present?
      @vendors = @commissions.map { |c| c[:nombre].to_s.strip }.compact.uniq.sort
    else
      @vendors = raw_details.map { |d| d.transform_keys(&:to_s)["vendedor"] }.compact.uniq.sort
    end
    
    @years = ["2025", "2026"]
    @dates = (1..12).map { |m| "#{@selected_year}-#{m.to_s.rjust(2, '0')}" }
    
    rescue Faraday::Error, UnauthorizedError => e
      session[:api_token] = nil
      redirect_to login_path, alert: "Tu sesión ha expirado o hubo un error de conexión."
    rescue => e
      Rails.logger.error("DASHBOARD DATA ERROR: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
      @details = []
      @commissions = []
      @products = []
      @product_commissions = []
      flash.now[:error] = "Error al cargar datos de la API: #{e.message}"
    end
  end

  def flatten_nested_data(invoices, mode = :vendor)
    flattened_items = []

    invoices.each do |inv|
      # 'inv' ya tiene las llaves como strings gracias al map previo
      items = inv["fd"] || []
      
      items.each do |item|
        item = item.transform_keys(&:to_s)
        
        # Buscar Descripción del Producto (Usando campos exactos: prod y descripcion)
        prod_code = item["prod"].to_s.strip
        
        product_info = @products_map[prod_code]
        prod_desc = product_info ? product_info[:descripcion] : prod_code

        # Determinar Comisión
        comision_pct = 0.0

        if mode == :vendor
          vendedor_name = inv["vendedor"].to_s.strip.upcase
          tipo_cliente = inv["tipo_cliente"].to_s.upcase
          com_info = @commissions_map[vendedor_name]
          
          if com_info
            if tipo_cliente.include?("PRIVADO")
              comision_pct = (com_info[:comision_priv] || com_info[:comision_privado]).to_f
            elsif tipo_cliente.include?("PUBLICO")
              comision_pct = (com_info[:comision_pub] || com_info[:comision_publico]).to_f
            end
          end
        elsif mode == :product
          # Nueva lógica: Comisión por Producto
          prod_com_info = @product_commissions_map[prod_code]
          if prod_com_info
            # Suponemos que el campo es 'comision' en Repr_Comision_Prod
            comision_pct = (prod_com_info[:comision] || prod_com_info[:comision_pct]).to_f
          else
            # Si el producto no tiene comisión definida, lo saltamos en el modo "Productos"
            next
          end
        end

        precio_item = item["precio_soles"].to_f
        comision_soles = precio_item * comision_pct

        # Formatear fecha: dd/mm/yyyy
        raw_date = inv["fecha_emision"]
        formatted_date = begin
          Time.parse(raw_date.to_s).strftime("%d/%m/%Y")
        rescue
          raw_date
        end

        flattened_items << {
          numero_factura: inv["nro_fact"] || inv["numero_factura"],
          fecha_emision: formatted_date,
          vendedor: inv["vendedor"],
          tipo_cliente: inv["tipo_cliente"],
          cancelado: inv["cancelado"],
          # Campos del Item (fd)
          producto_codigo: prod_code,
          producto_desc: prod_desc,
          precio_soles: precio_item,
          comision_pct: comision_pct,
          comision_soles: comision_soles
        }
      end
    end
    
    flattened_items
  end

  def calculate_kpis(details, total_api_count)
    # Sumarizar montos convertidos a coma flotante (con .to_f)
    total_monto = details.sum { |d| d["monto_soles"].to_f }
    total_cobrado = details.sum { |d| d["cobrado"].to_f }
    total_saldo = details.sum { |d| d["saldo"].to_f }

    {
      total_monto: total_monto,
      total_cobrado: total_cobrado,
      total_saldo: total_saldo,
      total_comprobantes: details.count,
      total_api_count: total_api_count
    }
  end

  def group_by_vendor(details)
    # Agrupar facturas por nombre de vendedor
    details.group_by { |d| d["vendedor"] || "SIN VENDEDOR" }.map do |vendor, items|
      {
        vendedor: vendor,
        monto_soles: items.sum { |d| d["monto_soles"].to_f },
        cobrado: items.sum { |d| d["cobrado"].to_f },
        saldo: items.sum { |d| d["saldo"].to_f },
        count: items.count
      }
    end.sort_by { |v| -v[:monto_soles] } # Ordenar por monto descendente
  end

  def group_data(details, granularity)
    # Agrupar por fecha extraída según granularidad (día o mes)
    details.group_by { |d|
      extract_date(d["fecha_emision"], granularity)
    }.map do |label, items|
      {
        label: label || "Sin Fecha",
        monto_soles: items.sum { |d| d["monto_soles"].to_f },
        cobrado: items.sum { |d| d["cobrado"].to_f },
        saldo: items.sum { |d| d["saldo"].to_f },
        count: items.count
      }
    end.sort_by { |m| m[:label] } # Ordenar cronológicamente
  end

  # Extrae la parte relevante de la fecha (YYYY-MM-DD o YYYY-MM)
  def extract_date(fecha, granularity)
    return nil if fecha.nil? || fecha.to_s.empty?
    date_obj = Date.parse(fecha.to_s) rescue nil
    return nil unless date_obj
    
    if granularity == :day
      date_obj.strftime("%Y-%m-%d")
    else
      date_obj.strftime("%Y-%m")
    end
  end

  # extract_date_by_granularity: Extrae la parte relevante de la fecha (YYYY-MM-DD o YYYY-MM)

  def products_json
    client = ApiClient.new(session[:api_token])
    products = Rails.cache.fetch("si_productos", expires_in: 4.hours) do
      client.fetch_products
    end
    
    # Soporte opcional para filtrar por lista de códigos (batching)
    requested_codes = params[:codes].to_s.split(',').map(&:strip)
    
    # Mapear a hash codigo => descripcion (Usando campos exactos: codigo y descripcion)
    products_map = products.each_with_object({}) do |p, hash|
      code = p[:codigo].to_s.strip
      next unless code
      
      # Si se solicitaron códigos específicos, saltar los que no estén en la lista
      next if requested_codes.any? && !requested_codes.include?(code)
      
      desc = p[:descripcion] || code
      hash[code] = desc.to_s.strip
    end
    
    render json: products_map
  end
end
