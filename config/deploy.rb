# This is a simple capfile that will deploy the broker to the host 'eshq'
set :application, "eventsource-broker"
set :repository,  "./dist/app"

set :scm, :none
set :deploy_via, :copy
set :deploy_to, "/usr/local/#{application}"

set :use_sudo, false

role :web, "eshq"
role :app, "eshq"
role :db,  "eshq", :primary => true

after "deploy:update_code", "deploy:symlink_configuration_files"
namespace :deploy do
	task :symlink_configuration_files do
	    run "ln -nfs #{shared_path}/config/app.cfg #{release_path}/config/app.cfg"
	end
end
