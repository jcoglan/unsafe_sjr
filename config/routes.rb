UnsafeSjr::Application.routes.draw do
  # The priority is based upon order of creation: first created -> highest priority.
  # See how all your routes lay out with "rake routes".

  get '/users/:username', :to => 'users#login'

  resources :notes
end
