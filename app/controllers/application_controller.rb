class ApplicationController < ActionController::Base
  
  before_action :authenticate_user!
  
  private

  def authenticate_user!
    unless session[:api_token]
      if request.xhr?
        render json: { error: "Sesión expirada" }, status: :unauthorized
      else
        redirect_to login_path
      end
    end
  end
end
