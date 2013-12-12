class UsersController < ApplicationController
  def login
    user = User.find_or_create_by(:username => params[:username])
    session[:user_id] = user.id
    redirect_to '/notes'
  end
end

