class DashboardController < ApplicationController
  def index
    @active_tab = params[:tab] || "panel"
    load_data
  end

  def panel
    @active_tab = "panel"
    load_data
    render partial: "dashboard/tabs/panel", locals: { dashboard: @dashboard, details: @details }
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

  def load_data
    # Inicializamos el cliente API con el token de la sesión actual
    client = ApiClient.new(session[:api_token])

    # Determinar rango de fechas seleccionado
    @selected_year = params[:year] || Date.today.year.to_s
    
    # Lógica de Selección de Mes por Defecto:
    # 1. Si no se selecciona nada (params[:date_range] vacío), intentamos mostrar el mes actual.
    #    Pero solo si el año seleccionado coincide con el año actual.
    current_month_str = Date.today.strftime("%Y-%m")
    
    if params[:date_range].blank?
      if @selected_year == Date.today.year.to_s
        @selected_month = current_month_str # Mostrar Mes Actual
      else
        @selected_month = "Todas" # Si es otro año, mostrar "Todas" (o podría ser necesario validar)
      end
    else
      @selected_month = params[:date_range]
    end
    
    start_date = nil
    end_date = nil

    if @selected_month.present? && @selected_month != "Todas"
      # Caso: Un mes específico seleccionado (ej: "2026-02")
      start_date = Date.strptime(@selected_month, "%Y-%m")
      end_date = start_date.end_of_month
    else
      # Caso: "Todas" seleccionado -> Tomamos todo el año completo
      start_date = Date.new(@selected_year.to_i, 1, 1)
      end_date = Date.new(@selected_year.to_i, 12, 31)
    end

    # Formatear fechas para la API
    # IMPORTANTE: end_date incluye hasta el último segundo del día (23:59:59)
    # para asegurar que se incluyan registros del último día del mes.
    start_date_str = start_date.strftime("%Y-%m-%d")
    end_date_str = end_date.strftime("%Y-%m-%d 23:59:59")

    # Obtener datos filtrados desde la API (Filtrado en el Servidor / Server-side)
    # Pedimos hasta 50 páginas (que con page_size=1000 son 50,000 registros),
    # suficiente para cubrir un mes o un año con actividad normal.
    api_data = client.fetch_details_pages(max_pages: 50, start_date: start_date_str, end_date: end_date_str)
    raw_details = api_data[:results] || []

    # Normalizar claves a strings (para consistencia)
    @details = raw_details.map { |d| d.transform_keys(&:to_s) }

    # Filtro de Negocio: Solo mostrar facturas pagadas (cancelado == 'S')
    @details = @details.select { |d| d["cancelado"] == "S" }

    # Aplicar filtro de vendedor (Client-side / Filtrado en Cliente)
    # Esto se hace aquí porque la API podría no soportar filtro directo por vendedor de forma sencilla,
    # o porque ya tenemos los datos en memoria.
    if params[:vendor].present? && params[:vendor] != "Todas"
      @details = @details.select { |d| d["vendedor"] == params[:vendor] }
    end

    # Calcular KPIs (Indicadores Clave de Desempeño)
    @dashboard = calculate_kpis(@details, api_data[:count] || 0)
    @vendor_data = group_by_vendor(@details)
    
    # Agrupar datos para el gráfico de línea
    # LÓGICA DE GRANULARIDAD:
    # - Si hay un mes seleccionado -> Agrupar por DÍA (:day) para ver detalle diario.
    # - Si es "Todas" -> Agrupar por MES (:month) para ver evolución anual.
    granularity = (@selected_month != "Todas") ? :day : :month
    @monthly_data = group_data(@details, granularity)
    
    # Obtener lista única de vendedores para el filtro
    @vendors = raw_details.map { |d| d.transform_keys(&:to_s)["vendedor"] }.compact.uniq.sort
    
    # Generar lista de años y meses para los selectores del frontend
    @years = ["2025", "2026"]
    @dates = (1..12).map { |m| "#{@selected_year}-#{m.to_s.rjust(2, '0')}" }
  end

  def calculate_kpis(details, total_api_count)
    # Sumarizar montos convertidos a float (con .to_f)
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

  # filter_by_date eliminado ya que ahora filtramos en el servidor
end
