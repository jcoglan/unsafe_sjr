class NotesController < ApplicationController
  before_filter do
    @user = User.find_by(:id => session[:user_id])
    render(:text => 'Forbidden', :status => 403) unless @user
  end

  def index
  end

  def create
    note_params = params.require(:note).permit(:title, :body)
    @note = @user.notes.create(note_params)
  end
end

