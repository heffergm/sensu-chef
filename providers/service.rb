def sensu_path
  "/opt/sensu"
end

def sensu_ctl
  "#{sensu_path}/bin/sensu-ctl"
end

def service_pipe
  "/opt/sensu/sv/#{new_resource.name}/supervise/ok"
end

def service_path
  "/opt/sensu/sv/service/#{new_resource.name}"
end

def sensu_runit_service_enabled?
  ::File.symlink?(sensu_service_path) && ::FileTest.pipe?(sensu_service_pipe)
end

def enable_sensu_runsvdir
  execute "configure_sensu_runsvdir_#{new_resource.service}" do
    command "#{sensu_ctl} configure"
    not_if "#{sensu_ctl} configured?"
  end

  # Keep on trying till the job is found :(
  execute "wait_for_sensu_runsvdir_#{new_resource.service}" do
    command "#{sensu_ctl} configured?"
    retries 30
  end
end

def load_current_resource
  @sensu_svc = run_context.resource_collection.lookup("service[#{new_resource.service}]") rescue nil
  @sensu_svc ||= case new_resource.init_style
  when "sysv"
    service new_resource.name do
      provider node.platform_family =~ /debian/ ? Chef::Provider::Service::Init::Debian : Chef::Provider::Service::Init::Redhat
      supports :status => true, :restart => true
      action :nothing
      subscribes :restart, resources("ruby_block[sensu_service_trigger]"), :delayed
    end
  end
end

action :enable do
  case new_resource.init_style
  when "sysv"
    @sensu_svc.run_action(:enable)
    new_resource.updated_by_last_action(@sensu_svc.updated_by_last_action?)
  when "runit"
    enable_sensu_runsvdir

    ruby_block "block_until_runsv_#{new_resource.name}_available" do
      block do
        Chef::Log.debug("waiting until named pipe #{sensu_service_pipe} exists")
        until ::FileTest.pipe?(sensu_service_pipe)
          sleep(1)
          Chef::Log.debug(".")
        end
      end
      action :nothing
    end

    execute "sensu-ctl_#{new_resource.name}_enable" do
      command "#{sensu_ctl} #{new_resource.name} enable"
      not_if { @service_enabled }
      notifies :create, "ruby_block[block_until_runsv_#{new_resource.name}_available]", :immediately
    end

    service new_resource.name do
      start_command "#{sensu_ctl} #{new_resource.name} start"
      stop_command "#{sensu_ctl} #{new_resource.name} stop"
      status_command "#{sensu_ctl} #{new_resource.name} status"
      restart_command "#{sensu_ctl} #{new_resource.name} restart"
      supports :restart => true, :status => true
      action [:start]
      subscribes :restart, resources("ruby_block[sensu_service_trigger]"), :delayed
    end
  end
end

action :disable do
  case new_resource.init_style
  when "sysv"
    service new_resource.name do
      provider node.platform_family =~ /debian/ ? Chef::Provider::Service::Init::Debian : Chef::Provider::Service::Init::Redhat
      action [:disable]
    end
  when "runit"
    execute "sensu-ctl_#{new_resource.name}_disable" do
      command "#{sensu_ctl} #{new_resource.name} disable"
      only_if { @service_enabled }
    end

    new_resource.updated_by_last_action(disable_svc.updated_by_last_action?)
  end
end

action :start do
  @sensu_svc.run_action(:start)
  new_resource.updated_by_last_action(@sensu_svc.updated_by_last_action?)
end

action :stop do
  @sensu_svc.run_action(:stop)
  new_resource.updated_by_last_action(@sensu_svc.updated_by_last_action?)
end

action :restart do
  @sensu_svc.run_action(:restart)
  new_resource.updated_by_last_action(@sensu_svc.updated_by_last_action?)
end
