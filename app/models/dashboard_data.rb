class DashboardData
  attr_reader :summary, :details

  def initialize(summary_data, details_data)
    @summary = summary_data
    @details = details_data
  end

  def total_contracts
    # Assuming the API returns a list of summary objects or we calculate from details
    # This logic depends on the exact JSON structure. 
    # Based on the user request, "Fact_Detalle" is likely the main source.
    @details.count
  end

  def total_amount_without_igv
    @details.sum { |d| d[:Monto_Sin_IGV].to_f }
  end

  def total_commission
    @details.sum { |d| d[:Monto_Comision].to_f }
  end

  def total_without_commission
    # Assuming this is calculated as Total - Commission or similar?
    # Or maybe there's a specific field.
    # For now, let's guess it's Total Amount - Commission, or a separate sum.
    # The screenshot shows "Monto Total sin Comision". 
    # Let's assume it's the sum of amounts where Commission is 0 or just a derived value.
    # We will just use Total Amount - Commission for now unless we see a field.
    total_amount_without_igv - total_commission
  end

  def formatted_details
    @details.map do |d|
      {
        comprobante: d[:Comprobante],
        formulario: d[:Formulario],
        numero: d[:Numero],
        monto_sin_igv: d[:Monto_Sin_IGV],
        monto_comision: d[:Monto_Comision],
        vendedor: d[:Vendedor], # Assuming this field exists based on screenshot
        fecha: d[:Fecha] # Assuming date field
      }
    end
  end
end
