Rails.application.routes.draw do
  # Revela el estado de salud en /up que devuelve 200 si la aplicación arranca sin excepciones, de lo contrario 500.
  # Puede ser usado por balanceadores de carga y monitores de tiempo de actividad para verificar que la aplicación está viva.
  get "up" => "rails/health#show", as: :rails_health_check

  # Autenticación
  get "login", to: "sessions#new"
  post "login", to: "sessions#create"
  delete "logout", to: "sessions#destroy"

  # Panel de Control (Dashboard)
  get "dashboard/index"
  get "productos", to: "dashboard#productos"
  get "vendedor", to: "dashboard#vendedor"
  get "reporte", to: "dashboard#reporte"
  get "products", to: "dashboard#products_json"

  root "dashboard#index"
end
