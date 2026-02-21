class ApplicationController < ActionController::Base
  
  before_action :authenticate_user!
  
  private

  def authenticate_user!
    unless session[:api_token]
      redirect_to login_path
    end
  end
end
