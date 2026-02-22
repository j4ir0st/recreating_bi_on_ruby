class SessionsController < ApplicationController
  skip_before_action :authenticate_user!, only: [:new, :create]

  def new
    render layout: "auth"
  end

  def create
    token = ApiClient.authenticate(params[:username], params[:password])

    if token
      session[:api_token] = token
      session[:username] = params[:username]
      
      # Obtener nombre completo del usuario desde la API
      begin
        client = ApiClient.new(token)
        users = client.fetch_users
        current_user = users.find { |u| u[:username] == params[:username] }
        
        if current_user
          session[:first_name] = current_user[:first_name]
          session[:last_name] = current_user[:last_name]
        end
      rescue => e
        Rails.logger.error("Error al obtener detalles del usuario: #{e.message}")
      end

      redirect_to root_path, notice: "Sesión iniciada correctamente"
    else
      flash.now[:alert] = "Usuario o contraseña inválidos"
      render :new, layout: "auth", status: :unprocessable_entity
    end
  end

  def destroy
    session[:api_token] = nil
    session[:username] = nil
    session[:first_name] = nil
    session[:last_name] = nil
    redirect_to login_path, notice: "Sesión cerrada"
  end
end
