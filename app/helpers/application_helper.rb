module ApplicationHelper
  MES_NOMBRES_ES = %w[enero febrero marzo abril mayo junio julio agosto septiembre octubre noviembre diciembre].freeze

  # Formatea una cadena YYYY-MM al formato '2026 febrero 24->23'
  def mes_label(month_str)
    return "" if month_str.blank?
    year, m = month_str.split('-').map(&:to_i)
    nombre = MES_NOMBRES_ES[m - 1] || month_str
    "#{year} #{nombre} 24->23"
  end
end
