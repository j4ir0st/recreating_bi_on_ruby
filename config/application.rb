require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
# require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
# require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
# require "action_cable/engine"
# require "rails/test_unit/railtie"

# Requiere las gemas listadas en el Gemfile, incluyendo aquellas
# limitadas a :test, :development o :production.
Bundler.require(*Rails.groups)

module ComisionesDashboard
  class Application < Rails::Application
    # Inicializar configuraciones predeterminadas para la versión de Rails generada originalmente.
    config.load_defaults 7.2

    # Por favor, añada a la lista `ignore` cualquier otro subdirectorio de `lib` que
    # no contenga archivos `.rb`, o que no deba sers cargado o precargado.
    # Ejemplos comunes son `templates`, `generators` o `middleware`.
    config.autoload_lib(ignore: %w[assets tasks])

    # La configuración para la aplicación, motores y railties va aquí.
    #
    # Estos ajustes pueden ser sobrescritos en entornos específicos usando los archivos
    # en config/environments, que se procesan después.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # No generar archivos de prueba del sistema.
    config.generators.system_tests = nil

    # Middleware para asegurar que Rails conozca el subdirectorio (IIS Proxy Fix)
    config.middleware.insert_before 0, Rack::Config do |env|
      env['SCRIPT_NAME'] = '/app_comisiones' if env['SCRIPT_NAME'].to_s.empty?
    end

    # Configuración para subdirectorio
    config.relative_url_root = "/app_comisiones"
  end
end
