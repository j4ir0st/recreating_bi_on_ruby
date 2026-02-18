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
      redirect_to root_path, notice: "Sesión iniciada correctamente"
    else
      flash.now[:alert] = "Usuario o contraseña inválidos"
      render :new, layout: "auth", status: :unprocessable_entity
    end
  end

  def destroy
    session[:api_token] = nil
    session[:username] = nil
    redirect_to login_path, notice: "Sesión cerrada"
  end
end
