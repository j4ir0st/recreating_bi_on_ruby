class DashboardController < ApplicationController
  rescue_from Exception, with: :handle_unexpected_error

  def index
    @active_tab = params[:tab] || "vendedor"
    if @active_tab == "supervisor"
      return unless prepare_supervisor_data
    else
      return unless load_data
    end
  end

  def productos
    @active_tab = "productos"
    return unless load_data
    render partial: "dashboard/tabs/productos", locals: { dashboard: @dashboard, details: @product_details }
  end

  def vendedor
    @active_tab = "vendedor"
    return unless load_data
    render partial: "dashboard/tabs/vendedor", locals: { dashboard: @dashboard, vendor_data: @vendor_data }
  end

  def reporte
    @active_tab = "reporte"
    return unless load_data
    render partial: "dashboard/tabs/reporte", locals: { dashboard: @dashboard, monthly_data: @monthly_data }
  end

  def audit
    @active_tab = "historial"
    # Inicializar valores mínimos necesarios para el layout (filtros)
    @selected_year = params[:year] || Date.today.year.to_s
    @selected_months = []
    raw_vendors = params[:vendor] || []
    @selected_vendors = raw_vendors.is_a?(Array) ? raw_vendors : [raw_vendors].reject(&:blank?)
    vendedores_filter = @selected_vendors.reject { |v| v == "Todas" }.first

    client = ApiClient.new(session[:api_token])
    # Cargar primera página de auditoría (60 registros), con filtros opcionales
    @audit_history = client.get_audit_history(
      page: 1,
      comprobantes_filter: params[:comprobantes_filter].to_s.strip,
      usuario_filter: params[:usuario_filter].to_s.strip,
      vendedores_filter: vendedores_filter
    )
    render partial: "dashboard/tabs/historial", locals: { audit_history: @audit_history }
  rescue UnauthorizedError
    render json: { error: "Sesión expirada. Por favor inicia sesión nuevamente." }, status: :unauthorized
  rescue => e
    Rails.logger.error("AUDIT ACTION ERROR: #{e.class}: #{e.message}\n#{e.backtrace.first(10).join("\n")}")
    render json: { error: "Error en Historial: #{e.class} - #{e.message}" }, status: :internal_server_error
  end

  # Endpoint JSON para paginación del historial (infinite scroll)
  def audit_data
    page = (params[:page] || 1).to_i
    raw_vendors = params[:vendor] || []
    selected_vendors = raw_vendors.is_a?(Array) ? raw_vendors : [raw_vendors].reject(&:blank?)
    vendedores_filter = selected_vendors.reject { |v| v == "Todas" }.first

    client = ApiClient.new(session[:api_token])
    result = client.get_audit_history(
      page: page,
      comprobantes_filter: params[:comprobantes_filter].to_s.strip,
      usuario_filter: params[:usuario_filter].to_s.strip,
      vendedores_filter: vendedores_filter
    )
    render json: { records: result[:records], has_more: result[:has_more], page: page }
  rescue => e
    Rails.logger.error("AUDIT DATA ERROR: #{e.message}")
    render json: { error: e.message }, status: :internal_server_error
  end

  def supervisor
    @active_tab = "supervisor"
    return unless prepare_supervisor_data
    render partial: "dashboard/tabs/supervisor", locals: { supervisor_rows: @supervisor_rows || [] }
  rescue UnauthorizedError
    render json: { error: "Sesión expirada. Por favor inicia sesión nuevamente." }, status: :unauthorized
  rescue => e
    Rails.logger.error("SUPERVISOR ACTION ERROR: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
    render json: { error: "Error en Supervisor: #{e.message}" }, status: :internal_server_error
  end

  def update_commission
    url = params[:url]
    paid = params[:paid]
    
    client = ApiClient.new(session[:api_token])
    result = client.update_commission_status(url, paid)
    
    if result[:success]
      render json: { success: true }
    else
      render json: { success: false, error: result[:error] }, status: :unprocessable_entity
    end
  rescue UnauthorizedError
    render json: { error: "Sesión expirada" }, status: :unauthorized
  rescue => e
    render json: { error: e.message }, status: :internal_server_error
  end

  def mass_update_commissions
    updates = params[:updates] || []
    Rails.logger.info("=== MASS UPDATE START: #{updates.size} cambios recibidos ===")
    client = ApiClient.new(session[:api_token])
    
    success_count = 0
    errors = []

    # Identificar el campo a actualizar según el tipo de comisión
    # Para Supervisor usamos 'comision_pagada_sup' (vendedor usa 'comision_pagada')
    field_to_patch = (params[:tipo_comision].to_s.downcase == 'supervisor') ? :comision_pagada_sup : :comision_pagada
    
    updates.each do |update|
      Rails.logger.info("=== PATCH: url=#{update["url"]} paid=#{update["paid"]} field=#{field_to_patch} ===")
      result = client.update_commission_status(update["url"], update["paid"], field: field_to_patch)
      if result[:success]
        success_count += 1
        Rails.logger.info("=== PATCH OK: #{update["url"]} ===")
      else
        Rails.logger.error("Error al actualizar comisión: #{update["url"]} - #{result[:error]}")
        errors << "Error en #{update["invoice_number"]}: #{result[:error]}"
      end
    end

    Rails.logger.info("=== MASS UPDATE: #{success_count} éxitos, #{errors.size} errores ===")

    # Crear auditoría si al menos una comisión fue actualizada exitosamente
    if success_count > 0
      begin
        # Calcular montos con signo: marcar = positivo, desmarcar = negativo
        # Solo incluir los que tuvieron éxito (simplificamos: usamos updates que enviaron correctamente)
        signed_items = updates.map do |u|
          amount = u["commission_amount"].to_f
          paid   = u["paid"].to_s == "true" || u["paid"] == true
          {
            invoice:    u["invoice_number"].to_s,
            amount:     paid ? amount : -amount,
            vendor:     u["vendor_name"].to_s.strip
          }
        end

        full_name = [session[:first_name], session[:last_name]].compact.join(" ").strip
        full_name = session[:username] || "Sistema" if full_name.blank?

        client.create_audit_entry(
          usuario: full_name,
          tipo_comision: params[:tipo_comision] || "Vendedor",
          detalles: signed_items
        )
      rescue => e
        Rails.logger.error("FALLO CREACIÓN AUDITORIA: #{e.message}")
      end
    end

    if errors.empty?
      render json: { success: true, message: "Actualización masiva completada con éxito (#{success_count} registros)." }
    else
      render json: { 
        success: false, 
        message: "Se actualizaron #{success_count} registros, pero hubo #{errors.size} errores.", 
        errors: errors 
      }, status: :multi_status
    end
  rescue UnauthorizedError
    render json: { error: "Sesión expirada" }, status: :unauthorized
  rescue => e
    render json: { error: e.message }, status: :internal_server_error
  end

  # Endpoint JSON: carga as\u00edncrona de descripciones de productos
  def products_json
    client = ApiClient.new(session[:api_token])
    requested_codes = params[:codes].to_s.split(',').map(&:strip).reject(&:empty?)
    return render json: {} if requested_codes.empty?

    Rails.logger.info("=== PRODUCTS JSON: #{requested_codes.length} codes: #{requested_codes.first(5).inspect} ===")

    products_map = Rails.cache.fetch("prod_batch_v3_#{requested_codes.sort.join(',')}", expires_in: 24.hours) do
      client.fetch_products_by_codes(requested_codes)
    end

    Rails.logger.info("=== PRODUCTS JSON result: #{products_map.length} descriptions found ===")

    missing = requested_codes - products_map.keys
    missing.each do |code|
      desc = Rails.cache.fetch("prod_desc_v2_#{code}", expires_in: 24.hours) do
        info = client.fetch_product_by_code(code)
        info ? info[:descripcion].to_s.strip : nil
      end
      products_map[code] = desc if desc.present?
    end

    render json: products_map
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

  private

  def load_filters_only(client = nil)
    client ||= ApiClient.new(session[:api_token])
    @commissions = Rails.cache.fetch("repr_comisiones", expires_in: 1.hour) do
      client.fetch_commissions
    end
    @vendors = @commissions.map { |c| c[:nombre].to_s.strip }.compact.uniq.reject { |v| v.upcase == "OFICINA" }.sort
  rescue => e
    Rails.logger.error("Error cargando filtros: #{e.message}")
    @vendors = []
  end

  MONTH_NAMES_ES = {
    1 => 'enero', 2 => 'febrero', 3 => 'marzo', 4 => 'abril',
    5 => 'mayo', 6 => 'junio', 7 => 'julio', 8 => 'agosto',
    9 => 'septiembre', 10 => 'octubre', 11 => 'noviembre', 12 => 'diciembre'
  }.freeze

  def prepare_supervisor_data
    # 0. Inicializar filtros (Sincronizado con load_data)
    raw_years = params[:year] || []
    @selected_years = raw_years.is_a?(Array) ? raw_years.reject(&:blank?) : [raw_years.to_s].reject(&:blank?)
    @selected_years = [Date.today.year.to_s] if @selected_years.empty?
    @selected_year = @selected_years.sort.last
    @selected_months = []
    @selected_vendors = []
    @selected_cancelado = "Todo"
    @years = ([Date.today.year, 2025].max).downto(2025).map(&:to_s).reverse
    @dates = (1..12).map { |m| "#{@selected_year}-#{m.to_s.rjust(2, '0')}" }
    @vendors = []

    min_year = @selected_years.map(&:to_i).min
    max_year = @selected_years.map(&:to_i).max
    start_date = Date.new(min_year - 1, 12, 24).strftime("%Y-%m-%d")
    end_date   = Date.new(max_year, 12, 23).strftime("%Y-%m-%d 23:59:59")

    client = ApiClient.new(session[:api_token])

    # 1. Cargar bases (Representantes y sus mapeos)
    @commissions = Rails.cache.fetch("repr_comisiones_v2", expires_in: 1.hour) { client.fetch_commissions }
    @commissions_map = (@commissions || []).index_by { |c| c[:nombre].to_s.strip.upcase }
    @vendors = (@commissions || []).map { |c| c[:nombre].to_s.strip }.compact.uniq.reject { |v| v.upcase == "OFICINA" }.sort

    supervisor_commissions = Rails.cache.fetch("repr_comisiones_sup", expires_in: 1.hour) { client.fetch_supervisor_commissions }
    supervisor_keys = Rails.cache.fetch("repr_comisiones_keys", expires_in: 1.hour) { client.fetch_supervisor_keys }

    # 2. Generar Filas (con el filtro de comision_pagada)
    pagada_filter = params[:comision_pagada] || "N"
    @supervisor_rows = build_supervisor_rows(supervisor_commissions, supervisor_keys, @commissions, client, start_date, end_date, pagada_filter)
    
    true
  rescue UnauthorizedError
    session[:api_token] = nil
    redirect_to login_path, alert: "Tu sesión ha expirado."
    return false
  rescue => e
    Rails.logger.error("PREPARE SUPERVISOR ERROR: #{e.message}")
    @supervisor_rows = []
    true # Mostrar vacío en lugar de explotar
  end

  def load_data
    # 0. Inicializar estado básico para evitar Nil en las vistas si algo falla
    @selected_year = params[:year] || Date.today.year.to_s  # backward compat single value
    raw_years = params[:year] || []
    @selected_years = raw_years.is_a?(Array) ? raw_years.reject(&:blank?) : [raw_years.to_s].reject(&:blank?)
    @selected_years = [Date.today.year.to_s] if @selected_years.empty?
    @selected_year = @selected_years.sort.last
    @selected_cancelado = params[:cancelado] || "Todo"

    raw_months = params[:date_range] || []
    @selected_months = raw_months.is_a?(Array) ? raw_months : [raw_months].reject(&:blank?)

    raw_vendors = params[:vendor] || []
    @selected_vendors = raw_vendors.is_a?(Array) ? raw_vendors : [raw_vendors].reject(&:blank?)

    @years = ([Date.today.year, 2025].max).downto(2025).map(&:to_s).reverse
    # @dates: genera YYYY-MM para todos los años seleccionados
    @dates = @selected_years.flat_map { |y| (1..12).map { |m| "#{y}-#{m.to_s.rjust(2, '0')}" } }.sort
    @vendors = []
    @details = []
    @commissions = []
    @products = []
    @product_commissions = []
    @vendor_details = []
    @product_details = []
    @vendor_data = []
    @monthly_data = []
    @dashboard = { total_monto: 0, total_cobrado: 0, total_saldo: 0, total_comprobantes: 0, total_api_count: 0 }

    begin
      client = ApiClient.new(session[:api_token])

      if @active_tab == "historial"
        vendedores_filter = @selected_vendors.reject { |v| v == "Todas" }.first
        @audit_history = client.get_audit_history(
          page: 1,
          comprobantes_filter: params[:comprobantes_filter].to_s.strip,
          usuario_filter: params[:usuario_filter].to_s.strip,
          vendedores_filter: vendedores_filter
        )
        # Carga la lista de vendedores desde caché (no llama a la API si ya está cacheado)
        @commissions = Rails.cache.fetch("repr_comisiones", expires_in: 1.hour) { client.fetch_commissions }
        @vendors = (@commissions || []).map { |c| c[:nombre].to_s.strip }.compact.uniq.reject { |v| v.upcase == "OFICINA" }.sort
        return true
      end

      start_date = nil
      end_date = nil

      if @selected_months.empty? || @selected_months.include?("Todas")
        # Sin filtro de mes: rango completo de todos los años seleccionados
        min_year = @selected_years.map(&:to_i).min
        max_year = @selected_years.map(&:to_i).max
        start_date = Date.new(min_year - 1, 12, 24)
        end_date   = Date.new(max_year, 12, 23)
      else
        # Lógica 24->23: el rango de facturas va del 24 del mes anterior al 23 del mes seleccionado
        parsed_months = @selected_months.map { |m| Date.strptime(m, "%Y-%m") rescue nil }.compact.sort
        if parsed_months.any?
          first_month = parsed_months.first
          last_month = parsed_months.last
          # Inicio: día 24 del mes anterior al primer mes seleccionado
          start_date = Date.new(first_month.year, first_month.month, 1) << 1
          start_date = Date.new(start_date.year, start_date.month, 24)
          # Fin: día 23 del último mes seleccionado
          end_date = Date.new(last_month.year, last_month.month, 23)
        else
          min_year = @selected_years.map(&:to_i).min
          max_year = @selected_years.map(&:to_i).max
          start_date = Date.new(min_year - 1, 12, 24)
          end_date   = Date.new(max_year, 12, 23)
        end
      end

      start_date_str = start_date.strftime("%Y-%m-%d")
      end_date_str = end_date.strftime("%Y-%m-%d 23:59:59")

      # Tabla maestra de comisiones (datos que rara vez cambian — cache 7 días)
      @commissions = Rails.cache.fetch("repr_comisiones", expires_in: 1.day) do
        client.fetch_commissions
      end
      @product_commissions = Rails.cache.fetch("repr_comisiones_prod", expires_in: 1.day) do
        client.fetch_product_commissions
      end

      @commissions_map = (@commissions || []).index_by { |c| c[:nombre].to_s.strip.upcase }
      @product_commissions_map = (@product_commissions || []).index_by { |pc| pc[:prod].to_s.strip }
      # @products_map intentionally empty — descriptions resolved async by JS via /products
      @products_map = {}

      # 2. Obtener Facturas
      api_params = {
        max_pages: 50, 
        start_date: start_date_str, 
        end_date: end_date_str,
        titulo_grat: 'N',
        estado__in: 'ACT,NCA'
      }

      if params[:comision_pagada].present? && params[:comision_pagada] != "Todo"
        api_params[:fd__comision_pagada] = (params[:comision_pagada] == "S")
      end

      if @selected_cancelado != "Todo"
        api_params[:cancelado] = @selected_cancelado
      end

      # Filtro de vendedores: sólo cuando hay vendedores específicos (NO cuando es "Todas" ni cuando está vacío)
      if @selected_vendors.any? && !@selected_vendors.include?("Todas")
        api_params[:vendedor__in] = @selected_vendors.map { |v| v.to_s.strip }.join(",")
      end

      # Pestaña productos sin vendedor → no hay nada que mostrar, evitar llamada a la API
      if @active_tab == "productos" && @selected_vendors.empty?
        return true
      end

      api_data = client.fetch_details_pages(**api_params)
      raw_details = api_data[:results] || []
      @details = raw_details.map { |d| d.transform_keys(&:to_s) }
      
      # [REGLA] Excluir vendedor "OFICINA" de los datos y cálculos
      @details.reject! { |d| d["vendedor"].to_s.strip.upcase == "OFICINA" }
      
      if @commissions.present?
        @details.each do |d|
          v_raw = d["vendedor"].to_s.strip
          if v_raw.include?('...') || v_raw.length >= 15
            v_clean = v_raw.gsub('...', '').strip.upcase
            full_name_info = @commissions.find { |c| c[:nombre].to_s.strip.upcase.start_with?(v_clean) }
            d["vendedor"] = full_name_info[:nombre].to_s.strip if full_name_info
          end
        end
      end
      
      # Filtros en memoria
      if @selected_months.any? && !@selected_months.include?("Todas")
        @details = @details.select do |d|
          begin
            f_emision = Date.parse(d["fecha_emision"].to_s)
            @selected_months.any? do |m|
              base = Date.strptime(m, "%Y-%m")
              # Rango 24->23: del día 24 del mes anterior al 23 del mes seleccionado
              m_end = Date.new(base.year, base.month, 23)
              prev = base << 1
              m_start = Date.new(prev.year, prev.month, 24)
              f_emision >= m_start && f_emision <= m_end
            end
          rescue
            true
          end
        end
      end

      # (El filtro cancelado ya se aplicó en el servidor via cancelado)
      
      # (El filtro de vendedores ya se aplicó en el servidor via vendedor__in)

      # 3. Procesar Datos para Vistas
      @dashboard = calculate_kpis(@details, api_data[:count] || 0)
      @vendor_data = group_by_vendor(@details)
      granularity = (@selected_months.length == 1) ? :day : :month
      @monthly_data = group_data(@details, granularity)
      
      @vendor_details = flatten_nested_data(@details, :vendor)
      @product_details = flatten_nested_data(@details, :product)
      # Orden por defecto en Productos: Clase A primero, luego B, luego C; dentro de cada clase por fecha desc
      clase_order = { 'A' => 0, 'B' => 1, 'C' => 2 }
      @product_details = @product_details.sort_by do |item|
        cls  = clase_order.fetch(item[:clase].to_s.strip.upcase, 9)
        date = (Date.parse(item[:fecha_emision].to_s) rescue Date.new(2000))
        [cls, -date.to_time.to_i]
      end

      # Listas para filtros (Excluir OFICINA)
      if @commissions.present?
        @vendors = @commissions.map { |c| c[:nombre].to_s.strip }.compact.uniq.reject { |v| v.upcase == "OFICINA" }.sort
      else
        @vendors = raw_details.map { |d| d.transform_keys(&:to_s)["vendedor"] }.compact.uniq.reject { |v| v.to_s.upcase == "OFICINA" }.sort
      end
      
      true
    rescue Faraday::Error, UnauthorizedError => e
      session[:api_token] = nil
      redirect_to login_path, alert: "Tu sesión ha expirado o hubo un error de conexión."
      return false
    rescue => e
      Rails.logger.error("DASHBOARD DATA ERROR: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
      flash.now[:error] = "Error al cargar datos de la API: #{e.message}"
      true # Permitir renderizar con tablas vacías
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
            clase = prod_com_info[:clase].to_s.strip.upcase
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
          invoice_url: item["url"], # URL específica para el recurso según fd:url
          numero_factura: inv["nro_fact"] || inv["numero_factura"],
          fecha_emision: formatted_date,
          vendedor: inv["vendedor"],
          tipo_cliente: inv["tipo_cliente"],
          nombre_cliente: inv["nombre_cliente"] || inv["cliente"], # Nombre del cliente desde CABECERA
          cancelado: inv["cancelado"],
          comision_pagada: item["comision_pagada"], # Estado de pago
          clase: clase, # Clase del producto (A, B, C)
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

  # ====== Métodos privados para la pestaña Supervisor ======

  # Construye las filas de la tabla Supervisor cruzando Repr_Comision_Sup con Repr_ComisionKey
  def build_supervisor_rows(supervisor_commissions, supervisor_keys, commissions_data, client, start_date, end_date, pagada_filter)
    # 1. Crear mapa de vendedores por supervisor
    # Usamos tanto el nombre como el ID/URL si están presentes para mayor robustez
    sup_vendors_map = Hash.new { |h, k| h[k] = [] }
    (supervisor_keys || []).each do |key_record|
      # Rcs_id suele ser el ID o URL del supervisor
      sup_id = key_record[:rcs_id].to_s.strip
      # Rc_id suele ser el nombre o ID del vendedor
      vendor_id = key_record[:rc_id].to_s.strip
      
      if sup_id.present? && vendor_id.present?
        # Almacenamos por el identificador del supervisor
        sup_vendors_map[sup_id] << vendor_id
        # También intentamos por el ID extraído de la URL si es el caso
        if sup_id.include?("/")
          id_part = sup_id.split('/').last
          sup_vendors_map[id_part] << vendor_id if id_part.present?
        end
      end
    end

    # 2. Procesar cada supervisor
    (supervisor_commissions || []).map do |sup|
      nombre = (sup[:nombre] || sup["nombre"] || "").strip
      comision_pct = (sup[:comision] || sup["comision"] || 0).to_f
      sup_url = sup[:url].to_s
      sup_id_from_url = sup_url.split('/').last

      # Buscar vendedores asignados usando nombre, url o id extraído
      assigned_vendors = []
      assigned_vendors.concat(sup_vendors_map[nombre] || [])
      assigned_vendors.concat(sup_vendors_map[sup_url] || [])
      assigned_vendors.concat(sup_vendors_map[sup_id_from_url] || [])
      assigned_vendors = assigned_vendors.uniq.map(&:strip).reject(&:blank?)

      vendor_data = []
      total_sup_full = 0.0

      if assigned_vendors.any?
        # BATCH FETCH: Pedir todos los vendedores del supervisor en una (o pocas) llamadas
        # Dividimos en grupos de 10 para no saturar la URL si hay demasiados
        assigned_vendors.each_slice(10) do |vendor_group|
          batch_results = fetch_batch_vendor_commission(client, vendor_group, start_date, end_date, pagada_filter)
          
          batch_results.each do |v_nombre, result|
            v_total = result[:total_vendedor]
            v_invoices = result[:invoices]
            v_sup = v_total * comision_pct
            
            vendor_data << {
              nombre: v_nombre,
              total_vendedor: v_total,
              total_supervisor: v_sup,
              invoices: v_invoices
            }
            total_sup_full += v_sup
          end
        end
      end

      {
        supervisor: nombre,
        comision_pct: comision_pct,
        vendor_data: vendor_data,
        total_supervisor: total_sup_full
      }
    end
  end

  # Nueva función para obtener comisiones de varios vendedores a la vez (Optimización)
  def fetch_batch_vendor_commission(client, vendor_names, start_date, end_date, pagada_filter)
    api_params = {
      max_pages: 15, # Reducido para evitar el "massive load" por cada supervisor
      start_date: start_date,
      end_date: end_date,
      titulo_grat: 'N',
      estado__in: 'ACT,NCA',
      cancelado: 'S',
      canje: 'T018',
      vendedor__in: vendor_names.join(",")
    }
    
    if pagada_filter.present? && pagada_filter != "Todo"
      # Usamos doble underscore para el filtro de la API
      api_params[:fd__comision_pagada_sup] = (pagada_filter == "S")
    end

    api_data = client.fetch_details_pages(**api_params)
    all_details = (api_data[:results] || []).map { |d| d.transform_keys(&:to_s) }
    
    # Agrupar por vendedor para retornar resultados individuales
    # Inicializar con todos los nombres para asegurar que existan aunque no tengan datos
    results_by_vendor = vendor_names.each_with_object({}) do |name, h|
      h[name] = { total_vendedor: 0.0, invoices: [] }
    end

    all_details.each do |inv|
      v_name = inv["vendedor"].to_s.strip
      # Intentar encontrar el nombre clave en el map (manejo de nombres truncados si aplica)
      target_name = vendor_names.find { |n| v_name.upcase.start_with?(n.upcase) } || v_name
      
      results_by_vendor[target_name] ||= { total_vendedor: 0.0, invoices: [] }
      
      inv_num = inv["numero_factura"] || inv["nro_fact"]
      tipo = inv["tipo_cliente"].to_s.upcase
      
      # Calcular porcentaje vendedor para este vendedor
      com_info = @commissions_map.present? ? @commissions_map[target_name.upcase] : nil
      pct_vend = 0.0
      if com_info
        pct_vend = tipo.include?("PRIVADO") ? (com_info[:comision_priv] || com_info[:comision_privado]).to_f : pct_vend
        pct_vend = tipo.include?("PUBLICO")  ? (com_info[:comision_pub] || com_info[:comision_publico]).to_f  : pct_vend
      end

      (inv["fd"] || []).each do |item|
        item = item.transform_keys(&:to_s)
        precio = item["precio_soles"].to_f
        prod_code = item["producto_codigo"] || item["prod"] || item["producto"]
        
        results_by_vendor[target_name][:invoices] << {
          numero_factura: inv_num,
          url: item["url"],
          precio_soles: precio,
          vendedor: v_name,
          producto_codigo: prod_code,
          comision_pagada_sup: (item["comision_pagada_sup"] == true)
        }
        results_by_vendor[target_name][:total_vendedor] += (precio * pct_vend)
      end
    end

    results_by_vendor
  end

  # extract_date_by_granularity: Extrae la parte relevante de la fecha (YYYY-MM-DD o YYYY-MM)

end
