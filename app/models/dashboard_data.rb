class DashboardData
  attr_reader :summary, :details

  def initialize(summary_data, details_data)
    @summary = summary_data
    @details = details_data
  end

  def total_contracts
    @details.count
  end

  def total_amount_without_igv
    @details.sum { |d| d[:Monto_Sin_IGV].to_f }
  end

  def total_commission
    @details.sum { |d| d[:Monto_Comision].to_f }
  end

  def total_without_commission
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
        vendedor: d[:Vendedor],
        fecha: d[:Fecha] 
      }
    end
  end
end
